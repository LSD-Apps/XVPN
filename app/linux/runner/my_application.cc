#include "my_application.h"

#include <dlfcn.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <glib/gstdio.h>
#include <signal.h>

#include <flutter_linux/flutter_linux.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// 与 Dart 侧 core/window_controls.dart、core/system_proxy.dart 共用的通道名。
// Windows 原生侧用的是同一个名字（见 windows/runner/flutter_window.cpp）。
static constexpr char kPlatformChannel[] = "com.xvpn.xvpn/platform";

// 托盘用到的 libayatana-appindicator3 符号。这里能编译，正是因为该库在构建期
// **不存在**依赖——它由运行期 dlopen 加载（见文件后半的「系统托盘」一节），
// 因此类型只能自己声明，句柄一律用 void*。
#define kTrayCategoryApplicationStatus 0
#define kTrayStatusActive 1

typedef void* (*TrayNewFn)(const char*, const char*, int);
typedef void (*TraySetStatusFn)(void*, int);
typedef void (*TraySetMenuFn)(void*, GtkMenu*);
typedef void (*TraySetIconFullFn)(void*, const char*, const char*);
typedef void (*TraySetTitleFn)(void*, const char*);

typedef struct {
  void* handle;
  TrayNewFn new_indicator;
  TraySetStatusFn set_status;
  TraySetMenuFn set_menu;
  TraySetIconFullFn set_icon_full;
  // 旧版 libappindicator3 里可能没有；为 nullptr 时跳过（标题不是必需的）。
  TraySetTitleFn set_title;
} TrayApi;

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* window_channel;
  GtkWindow* window;
  // 本会话是否由应用自绘窗口框。X11 为 TRUE，Wayland 为 FALSE。
  gboolean client_decorations;
  gboolean last_maximized;

  // ------------------------------------------------------------ 系统托盘
  TrayApi tray_api;
  // AppIndicator*。那个类型没有头文件，因此按 void* 持有。
  void* tray_indicator;
  GtkMenu* tray_menu;
  GtkWidget* tray_version_item;
  GtkWidget* tray_status_item;
  GtkWidget* tray_update_item;
  // 彩色图标的绝对路径；找不到实体文件时退回主题名 "xvpn"。灰色图标是它的
  // 去饱和副本，写进缓存目录后同样以绝对路径交给 indicator；做不出灰色时为
  // nullptr（此时退回彩色）。
  gchar* tray_icon_normal;
  gchar* tray_icon_grey;
  // Dart 最近一次推来的状态，供关窗收进托盘时写通知正文。
  gchar* tray_status_text;
  gboolean tray_connected;
  // 是否已经开始退出。置位后不重复发起（托盘退出 / SIGTERM / 关窗可能先后到达）。
  gboolean quit_requested;
  // Dart 侧收尾的兜底超时。Dart 没在超时内回话时强制退出，避免「点了退出没反应」。
  guint quit_fallback_id;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// ---------------------------------------------------------------- 窗口通道

// 一次异步方法调用的收尾。存在的意义只是把返回值释放掉，否则每次推送
// maximizedChanged 都会泄漏一个 FlMethodResponse。
static void push_method_done(GObject* source, GAsyncResult* result,
                             gpointer user_data) {
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(source), result, nullptr);
  (void)response;
}

// ---------------------------------------------------------------- 系统托盘
//
// 用 StatusNotifierItem（libayatana-appindicator3）而不是 GtkStatusIcon：后者已
// 弃用，且在 Wayland 下根本不会显示。
//
// 关键决定：**运行时 dlopen，不在构建期链接**。若写成链接依赖，用户在没装这个
// 库的机器上会连程序都起不来——动态链接器会直接报「找不到 so」并拒绝启动整个
// 进程。对 VPN 客户端这是不可接受的：托盘只是便利功能，绝不能决定应用能否运行。
// dlopen 的代价只是「没有库 → 应用照常启动，只是没有托盘图标」。这也意味着构建
// 机上不需要这个库，CMake 里只加 ${CMAKE_DL_LIBS}。

// 优先 ayatana 版，再退回旧的 libappindicator3。两者符号名相同，因此同一套
// 函数指针即可。
static void tray_api_load(TrayApi* api) {
  static const char* kCandidates[] = {
      "libayatana-appindicator3.so.1",
      "libappindicator3.so.1",
  };
  for (size_t i = 0; i < G_N_ELEMENTS(kCandidates); i++) {
    void* handle = dlopen(kCandidates[i], RTLD_LAZY | RTLD_LOCAL);
    if (handle == nullptr) {
      continue;
    }
    api->new_indicator =
        reinterpret_cast<TrayNewFn>(dlsym(handle, "app_indicator_new"));
    api->set_status = reinterpret_cast<TraySetStatusFn>(
        dlsym(handle, "app_indicator_set_status"));
    api->set_menu = reinterpret_cast<TraySetMenuFn>(
        dlsym(handle, "app_indicator_set_menu"));
    api->set_icon_full = reinterpret_cast<TraySetIconFullFn>(
        dlsym(handle, "app_indicator_set_icon_full"));
    api->set_title =
        reinterpret_cast<TraySetTitleFn>(dlsym(handle, "app_indicator_set_title"));
    // set_title 允许缺失（旧版没有）；其余四个缺一不可。
    if (api->new_indicator == nullptr || api->set_status == nullptr ||
        api->set_menu == nullptr || api->set_icon_full == nullptr) {
      dlclose(handle);
      api->new_indicator = nullptr;
      api->set_status = nullptr;
      api->set_menu = nullptr;
      api->set_icon_full = nullptr;
      api->set_title = nullptr;
      continue;
    }
    api->handle = handle;
    return;
  }
}

// 会话总线上是否有 StatusNotifierWatcher。
//
// 这是判断「托盘到底会不会显示」的依据：库装上了、indicator 对象也建出来了，
// 但没有这个 watcher 的话 SNI 图标没有任何宿主去显示，把窗口藏起来等于把用户
// 唯一的入口藏起来。逐个探测两个历史名：现代实现（KDE / GNOME 的 AppIndicator
// 扩展）用 org.kde.*，早期 ayatana 实现注册 org.ayatana.*。
static gboolean bus_name_has_owner(const char* name) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus == nullptr) {
    return FALSE;
  }
  // GIO 没有「这个名字有没有主」的便捷函数，直接问 D-Bus 守护进程本身：
  // org.freedesktop.DBus 的 NameHasOwner 就是为此存在的标准接口。
  //
  // 这里曾写成 `g_bus_name_has_owner(...)`——那个标识符在 GIO 里并不存在
  // （函数来自别的语言绑定），本机没有 GTK 工具链时编译不出来，直到
  // release 流水线首次真正编译 Linux runner 才暴露：
  //   error: use of undeclared identifier 'g_bus_name_has_owner'
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", name),
      G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (reply == nullptr) {
    return FALSE;
  }
  gboolean has_owner = FALSE;
  g_variant_get(reply, "(b)", &has_owner);
  return has_owner;
}

static gboolean tray_host_available(void) {
  return bus_name_has_owner("org.kde.StatusNotifierWatcher") ||
         bus_name_has_owner("org.ayatana.StatusNotifierWatcher");
}

// 「托盘可用」：库加载成功、indicator 建出来、且真的有 SNI 宿主。
// 只有三者都成立时才敢把窗口收进托盘（见 window_delete_event_cb）。
static gboolean tray_is_usable(MyApplication* self) {
  if (self->tray_indicator == nullptr) {
    return FALSE;
  }
  return tray_host_available();
}

// 挑一个存在的图标文件，返回绝对路径。优先 bundle 内的副本（linux/CMakeLists.txt
// 会把 packaging/icons/hicolor 一并装进 bundle），再退到系统图标主题。
//
// 为什么一定要文件而不是主题名：没有实体文件就无法做去饱和，而「未连接时灰掉」
// 是明确要的行为；文件路径也让自编译（flutter run）产物在系统没装 xvpn 图标时
// 照样有图标可用。
static gchar* find_icon_file(void) {
  static const int kSizes[] = {64, 128, 32, 48, 256, 24, 16};
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) {
    return nullptr;
  }
  g_autofree gchar* exe_dir = g_path_get_dirname(exe);
  // 前缀按优先级：bundle 根（本项目的安装布局）→ bundle 上一级（二进制在
  // usr/bin、图标在 usr/share 的系统安装）→ 系统目录。都是 hicolor 标准布局。
  g_autofree gchar* bundle_share =
      g_build_filename(exe_dir, "share", "icons", "hicolor", nullptr);
  g_autofree gchar* parent_share =
      g_build_filename(exe_dir, "..", "share", "icons", "hicolor", nullptr);
  const gchar* roots[] = {
      bundle_share,
      parent_share,
      "/usr/share/icons/hicolor",
      "/usr/local/share/icons/hicolor",
  };
  for (size_t i = 0; i < G_N_ELEMENTS(kSizes); i++) {
    g_autofree gchar* size_dir = g_strdup_printf("%dx%d", kSizes[i], kSizes[i]);
    for (size_t r = 0; r < G_N_ELEMENTS(roots); r++) {
      g_autofree gchar* candidate =
          g_build_filename(roots[r], size_dir, "apps", "xvpn.png", nullptr);
      if (g_file_test(candidate, G_FILE_TEST_IS_REGULAR)) {
        // 归一化掉路径里的 ".."，交给 indicator 的必须是一个能直接打开的路径。
        return g_canonicalize_filename(candidate, nullptr);
      }
    }
  }
  return nullptr;
}

// 复制一份并把 RGB 去饱和。有 alpha 通道时**原样保留**——边缘的抗锯齿信息全在
// alpha 里，只改 RGB 才能让边缘保持平滑（先把整张图合成到灰底再取整会得到一圈
// 黑边）。
//
// 刻意**不**要求必须有 alpha：仓库里 packaging/icons 的 hicolor 图标是 24 位
// RGB（实测 colorType=2，没有 alpha 通道），若照 Windows 端那样「没有 alpha 就
// 放弃」，未连接时会永远不灰。不透明的图没有 alpha 要保留，整张去饱和即可。
static GdkPixbuf* desaturated_copy(GdkPixbuf* source) {
  if (source == nullptr) {
    return nullptr;
  }
  GdkPixbuf* copy = gdk_pixbuf_copy(source);
  if (copy == nullptr) {
    return nullptr;
  }
  const int width = gdk_pixbuf_get_width(copy);
  const int height = gdk_pixbuf_get_height(copy);
  const int channels = gdk_pixbuf_get_n_channels(copy);
  const int rowstride = gdk_pixbuf_get_rowstride(copy);
  guchar* pixels = gdk_pixbuf_get_pixels(copy);
  if (width <= 0 || height <= 0 || channels < 3) {
    g_object_unref(copy);
    return nullptr;
  }
  for (int y = 0; y < height; y++) {
    guchar* row = pixels + static_cast<gsize>(y) * rowstride;
    for (int x = 0; x < width; x++) {
      guchar* pixel = row + static_cast<gsize>(x) * channels;
      // Rec.601 亮度权重，与 Windows 端口径一致。
      const int luminance =
          (pixel[0] * 299 + pixel[1] * 587 + pixel[2] * 114) / 1000;
      pixel[0] = static_cast<guchar>(luminance);
      pixel[1] = static_cast<guchar>(luminance);
      pixel[2] = static_cast<guchar>(luminance);
      // 第 4 个字节（alpha，若有）不动。
    }
  }
  return copy;
}

// 把去饱和后的图标写进缓存目录，返回绝对路径。SNI 的 IconName 允许绝对路径
// （libayatana-appindicator 在名字以 '/' 开头时把它原样写进 IconName），这也是
// 唯一能把运行期生成的图交给宿主进程的途径——appindicator 没有「直接设 pixbuf」
// 的公开接口。
static gchar* write_grey_icon(GdkPixbuf* grey) {
  g_autofree gchar* dir =
      g_build_filename(g_get_user_cache_dir(), "xvpn", nullptr);
  if (g_mkdir_with_parents(dir, 0700) != 0) {
    return nullptr;
  }
  g_autofree gchar* path = g_build_filename(dir, "tray-grey.png", nullptr);
  // 先写临时文件再改名：多实例同时启动时，宿主不会读到半张图（与代理备份的
  // 落盘做法一致）。
  g_autofree gchar* tmp = g_strdup_printf("%s.%u.tmp", path, g_random_int());
  g_autoptr(GError) error = nullptr;
  if (!gdk_pixbuf_savev(grey, tmp, "png", nullptr, nullptr, &error)) {
    g_warning("写入托盘灰色图标失败：%s",
              error != nullptr ? error->message : "未知错误");
    return nullptr;
  }
  if (g_rename(tmp, path) != 0) {
    g_warning("替换托盘灰色图标失败");
    g_unlink(tmp);
    return nullptr;
  }
  return g_strdup(path);
}

// 准备彩色与灰色图标路径。灰色做不出来时保持 nullptr，调用方会退回彩色。
static void prepare_tray_icons(MyApplication* self) {
  self->tray_icon_normal = find_icon_file();
  if (self->tray_icon_normal == nullptr) {
    // 找不到实体文件时退回图标主题名：至少装了主题图标的机器上还有图标，代价是
    // 没法去饱和（未连接不灰）——最坏是「不灰」，不是「没图标」。
    self->tray_icon_normal = g_strdup("xvpn");
    return;
  }
  GdkPixbuf* source = gdk_pixbuf_new_from_file(self->tray_icon_normal, nullptr);
  GdkPixbuf* grey = desaturated_copy(source);
  if (source != nullptr) {
    g_object_unref(source);
  }
  if (grey != nullptr) {
    self->tray_icon_grey = write_grey_icon(grey);
    g_object_unref(grey);
  }
}

// Dart 没在超时内回话时的兜底。触发即意味着收尾没能跑完，但用户不能因为托盘
// 点了「退出」而卡在一个关不掉的进程上——宁可少一次清理，也要退出去。
static gboolean quit_fallback_cb(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->quit_fallback_id = 0;
  if (self->quit_requested) {
    g_application_quit(G_APPLICATION(self));
  }
  return G_SOURCE_REMOVE;
}

// 结束进程前的统一入口：**先让 Dart 收尾**，再退出。
//
// Linux 上没有 Windows 的 WM_DESTROY / WM_QUERYENDSESSION 那样的退出钩子，而
// Dart 的收尾是异步的：还原系统代理要执行 gsettings 等外部命令、结束 sing-box
// 要等子进程真的退出。直接 g_application_quit() 会把这两步一起打断，用户会留下
// 一个指向死端口的系统代理和一个孤儿内核——正是本项目最不能接受的那类故障。
// 因此这里推一条 native→Dart 消息（与 maximizedChanged 同一机制），由 Dart 跑完
// AppState.disconnect 再回调 quitNow。
static void request_quit(MyApplication* self) {
  if (self->quit_requested) {
    return;
  }
  self->quit_requested = TRUE;
  if (self->window_channel == nullptr) {
    g_application_quit(G_APPLICATION(self));
    return;
  }
  g_autoptr(FlValue) args = fl_value_new_null();
  fl_method_channel_invoke_method(self->window_channel, "quitRequested", args,
                                  nullptr, push_method_done, nullptr);
  // 6 秒足够跑完 gsettings 与等内核退出（内核最多再等 3 秒）。
  self->quit_fallback_id = g_timeout_add_seconds(6, quit_fallback_cb, self);
}

// Dart 收尾完成（或放弃）后调用 quitNow，这里才真正退出。
static void finish_quit(MyApplication* self) {
  self->quit_requested = TRUE;
  if (self->quit_fallback_id != 0) {
    g_source_remove(self->quit_fallback_id);
    self->quit_fallback_id = 0;
  }
  g_application_quit(G_APPLICATION(self));
}

// SIGTERM / SIGINT：注销、关机、终端的 Ctrl+C 都会走这里。既然已经有了上面那条
// 干净的退出路径，就没有理由让这几条路径继续把 sing-box 子进程与系统代理留下。
static gboolean terminate_signal_cb(gpointer user_data) {
  request_quit(MY_APPLICATION(user_data));
  // 只处理第一次：退出流程已经启动，第二次信号按默认语义（直接结束）处理即可，
  // 万一 Dart 卡死，这仍是最后一条硬退出路径。
  return G_SOURCE_REMOVE;
}

static void tray_show_cb(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window == nullptr) {
    return;
  }
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_deiconify(self->window);
  gtk_window_present(self->window);
}

static void tray_quit_cb(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  request_quit(MY_APPLICATION(user_data));
}

// 「发现新版本」被点：显示主界面，并让 Dart 切到设置页的「版本更新」卡片。
//
// 与 Windows 端 kTrayMenuUpdate 分支逐步对齐：两步都做——只切页不显示窗口，
// 用户会觉得点了没反应；只显示窗口不切页，用户还得自己找。
static void tray_update_cb(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window != nullptr) {
    gtk_widget_show(GTK_WIDGET(self->window));
    gtk_window_deiconify(self->window);
    gtk_window_present(self->window);
  }
  if (self->window_channel == nullptr) {
    return;
  }
  // 与 request_quit 同一种写法：不带参数，用 null 而不是空列表。
  g_autoptr(FlValue) args = fl_value_new_null();
  fl_method_channel_invoke_method(self->window_channel, "trayOpenUpdate", args,
                                  nullptr, nullptr, nullptr);
}

/// 关窗收进托盘时发一次桌面通知，与 Windows 端气泡同语义。
static void notify_running_in_background(MyApplication* self) {
  const gchar* body = self->tray_connected
                          ? "已收至系统托盘，隧道仍在后台保持连接。"
                            "点击托盘图标可打开，右键可退出。"
                          : "已收至系统托盘，程序仍在后台运行。"
                            "点击托盘图标可打开，右键可退出。";
  g_autoptr(GNotification) notification = g_notification_new("XVPN");
  g_notification_set_body(notification, body);
  // 固定 id：同一次会话里反复关窗只刷新同一条，不堆通知。
  g_application_send_notification(G_APPLICATION(self), "xvpn-background",
                                  notification);
}

// 从载荷里取字符串字段。类型不对或不存在都当「没给」。
static const gchar* tray_string(FlValue* state, const char* key) {
  FlValue* value = fl_value_lookup_string(state, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}

// 应用 Dart 推来的托盘状态。字段与 Windows 端 ApplyTrayState 完全一致：
// version / status / connected / downRate / upRate / updateVersion
// （后三者只在有值时出现；速率仅已连接时附带）。
static void apply_tray_state(MyApplication* self, FlValue* state) {
  if (state == nullptr || fl_value_get_type(state) != FL_VALUE_TYPE_MAP) {
    return;
  }
  const gchar* version = tray_string(state, "version");
  const gchar* status = tray_string(state, "status");
  const gchar* update = tray_string(state, "updateVersion");
  const gchar* down_rate = tray_string(state, "downRate");
  const gchar* up_rate = tray_string(state, "upRate");
  FlValue* connected_value = fl_value_lookup_string(state, "connected");
  const gboolean connected =
      connected_value != nullptr &&
      fl_value_get_type(connected_value) == FL_VALUE_TYPE_BOOL &&
      fl_value_get_bool(connected_value);

  self->tray_connected = connected;
  g_free(self->tray_status_text);
  self->tray_status_text =
      (status != nullptr && *status != '\0') ? g_strdup(status) : nullptr;

  if (self->tray_indicator == nullptr) {
    return;
  }

  // 标题（多数宿主拿它当悬停提示）：与 Windows 端 UpdateTrayIcon 逐字一致。
  GString* title = g_string_new("XVPN");
  if (version != nullptr && *version != '\0') {
    g_string_append_printf(title, " %s", version);
  }
  if (status != nullptr && *status != '\0') {
    g_string_append_printf(title, " · %s", status);
  }
  if (connected &&
      ((down_rate != nullptr && *down_rate != '\0') ||
       (up_rate != nullptr && *up_rate != '\0'))) {
    g_string_append_printf(title, " · ↓%s ↑%s",
                           down_rate != nullptr ? down_rate : "",
                           up_rate != nullptr ? up_rate : "");
  }
  if (update != nullptr && *update != '\0') {
    g_string_append_printf(title, " · 发现新版本 v%s", update);
  }
  if (self->tray_api.set_title != nullptr) {
    self->tray_api.set_title(self->tray_indicator, title->str);
  }
  g_string_free(title, TRUE);

  // 菜单信息项与 Windows 端同序：状态 / 版本 / 条件性更新（更新可点）。
  if (self->tray_status_text != nullptr) {
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_status_item),
                            self->tray_status_text);
    gtk_widget_set_visible(self->tray_status_item, TRUE);
  } else {
    gtk_widget_set_visible(self->tray_status_item, FALSE);
  }
  if (version != nullptr && *version != '\0') {
    g_autofree gchar* label = g_strdup_printf("XVPN %s", version);
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_version_item), label);
    gtk_widget_set_visible(self->tray_version_item, TRUE);
  } else {
    gtk_widget_set_visible(self->tray_version_item, FALSE);
  }
  if (update != nullptr && *update != '\0') {
    g_autofree gchar* label =
        g_strdup_printf("发现新版本 v%s（打开更新界面）", update);
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_update_item), label);
    gtk_widget_set_visible(self->tray_update_item, TRUE);
  } else {
    gtk_widget_set_visible(self->tray_update_item, FALSE);
  }

  // 只有「已连接」用彩色，其余状态一律灰掉。灰色图标做不出来时退回彩色——
  // 宁可「没灰」，也不能把图标设成一个不存在的路径。
  const gchar* desired =
      connected ? self->tray_icon_normal : self->tray_icon_grey;
  if (desired == nullptr) {
    desired = self->tray_icon_normal;
  }
  if (desired != nullptr) {
    self->tray_api.set_icon_full(self->tray_indicator, desired, "XVPN");
  }
}

// 创建托盘。返回是否真的建出来了：库缺失、indicator 建不出来都返回 FALSE，
// 应用照常运行——这正是 dlopen 的目的。
static gboolean setup_tray(MyApplication* self) {
  tray_api_load(&self->tray_api);
  if (self->tray_api.handle == nullptr) {
    return FALSE;
  }
  prepare_tray_icons(self);

  self->tray_indicator = self->tray_api.new_indicator(
      "xvpn", "xvpn", kTrayCategoryApplicationStatus);
  if (self->tray_indicator == nullptr) {
    return FALSE;
  }

  // 菜单逐条对齐 Windows 端 ShowTrayMenu：
  // 显示主界面 / 状态（灰）/ 版本（灰）/ 更新提示（可点、条件出现）/ 退出。
  GtkWidget* menu = gtk_menu_new();
  GtkWidget* show_item = gtk_menu_item_new_with_label("显示主界面");
  g_signal_connect(show_item, "activate", G_CALLBACK(tray_show_cb), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), show_item);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
  self->tray_status_item = gtk_menu_item_new_with_label("");
  gtk_widget_set_sensitive(self->tray_status_item, FALSE);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), self->tray_status_item);
  self->tray_version_item = gtk_menu_item_new_with_label("XVPN");
  gtk_widget_set_sensitive(self->tray_version_item, FALSE);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), self->tray_version_item);
  // 更新项**保持可点**：它承载的是可操作的信息（应用里有下载与安装入口），
  // 做成不可点等于告诉用户有新版本却不给出路。是否出现由可见性控制
  // （见 apply_tray_state），因此不需要在这里灰掉它。
  self->tray_update_item = gtk_menu_item_new_with_label("");
  g_signal_connect(self->tray_update_item, "activate",
                   G_CALLBACK(tray_update_cb), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), self->tray_update_item);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
  GtkWidget* quit_item = gtk_menu_item_new_with_label("退出 XVPN");
  g_signal_connect(quit_item, "activate", G_CALLBACK(tray_quit_cb), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit_item);

  // 状态 / 更新项此刻还没有内容：show_all 会把所有子项显示出来，必须显式再
  // 藏回去，否则菜单里会多出空白项。
  gtk_widget_show_all(menu);
  gtk_widget_set_visible(self->tray_status_item, FALSE);
  gtk_widget_set_visible(self->tray_update_item, FALSE);

  self->tray_menu = GTK_MENU(menu);
  self->tray_api.set_menu(self->tray_indicator, self->tray_menu);
  if (self->tray_icon_normal != nullptr) {
    self->tray_api.set_icon_full(self->tray_indicator, self->tray_icon_normal,
                                 "XVPN");
  }
  if (self->tray_api.set_title != nullptr) {
    self->tray_api.set_title(self->tray_indicator, "XVPN");
  }
  self->tray_api.set_status(self->tray_indicator, kTrayStatusActive);
  return TRUE;
}

// 窗口关闭：有托盘 → 收进托盘；没有 → 走干净的退出流程（先收尾再退出）。
//
// 「有托盘」必须真的确认到 SNI 宿主（见 tray_is_usable），只看库在不在不够：
// 库在但没人显示图标时把窗口藏起来，用户会剩下一个既无窗口又无托盘图标的进程，
// 除了杀进程没有别的入口。
static gboolean window_delete_event_cb(GtkWidget* widget, GdkEvent* event,
                                       gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  (void)event;
  const gboolean was_visible = gtk_widget_get_visible(widget);
  // 先隐藏：无论哪条分支，用户的观感都是「窗口关掉了」。
  gtk_widget_hide(widget);
  if (tray_is_usable(self)) {
    // 与 Windows 端 WM_CLOSE → SW_HIDE 一致：关闭 = 收进托盘，只有托盘里的
    // 「退出 XVPN」才真正结束进程。首次收进时发通知，避免重复关窗刷屏。
    if (was_visible) {
      notify_running_in_background(self);
    }
    return TRUE;
  }
  // 没有托盘：不能只藏起来（用户会剩一个不可达的进程）。把退出交给统一的收尾
  // 流程，Dart 完成后再由原生退出。
  request_quit(self);
  return TRUE;
}

// 取当前指针的**根窗口**坐标。gtk_window_begin_move_drag /
// gtk_window_begin_resize_drag 要求的是根坐标而不是相对坐标。
static gboolean pointer_root_position(GtkWindow* window, gint* x, gint* y) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  if (display == nullptr) {
    return FALSE;
  }
  GdkSeat* seat = gdk_display_get_default_seat(display);
  if (seat == nullptr) {
    return FALSE;
  }
  GdkDevice* pointer = gdk_seat_get_pointer(seat);
  if (pointer == nullptr) {
    return FALSE;
  }
  // GTK3 的 gdk_device_get_position 返回 void（坐标由出参带出），因此不能直接
  // return 它的返回值——写成 `return gdk_device_get_position(...)` 会报
  // “cannot initialize return object of type 'gboolean' with an rvalue of type 'void'”。
  //
  // 该 API 自 GTK 3.22 起弃用，而 GTK3 并未提供替代品（官方的下一步是 GTK4），
  // 因此这里按 GLib 提供的方式就地屏蔽弃用告警：本工程开了 -Werror，
  // 不屏蔽会直接构建失败。
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  gdk_device_get_position(pointer, nullptr, x, y);
  G_GNUC_END_IGNORE_DEPRECATIONS
  return TRUE;
}

// 边名到 GdkWindowEdge。名字与 Dart 侧 WindowEdge.wireName 一一对应，
// 错一个字符就会得到一个「看起来点中了却没有反应」的缩放热区。
static gboolean edge_from_name(const gchar* name, GdkWindowEdge* edge) {
  if (g_strcmp0(name, "left") == 0) {
    *edge = GDK_WINDOW_EDGE_WEST;
  } else if (g_strcmp0(name, "right") == 0) {
    *edge = GDK_WINDOW_EDGE_EAST;
  } else if (g_strcmp0(name, "top") == 0) {
    *edge = GDK_WINDOW_EDGE_NORTH;
  } else if (g_strcmp0(name, "bottom") == 0) {
    *edge = GDK_WINDOW_EDGE_SOUTH;
  } else if (g_strcmp0(name, "topLeft") == 0) {
    *edge = GDK_WINDOW_EDGE_NORTH_WEST;
  } else if (g_strcmp0(name, "topRight") == 0) {
    *edge = GDK_WINDOW_EDGE_NORTH_EAST;
  } else if (g_strcmp0(name, "bottomLeft") == 0) {
    *edge = GDK_WINDOW_EDGE_SOUTH_WEST;
  } else if (g_strcmp0(name, "bottomRight") == 0) {
    *edge = GDK_WINDOW_EDGE_SOUTH_EAST;
  } else {
    return FALSE;
  }
  return TRUE;
}

static void window_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = self->window;
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (window == nullptr) {
    response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("no_window", "窗口尚未创建", nullptr));
  } else if (g_strcmp0(method, "clientDecorations") == 0) {
    // 能力查询必须在方法表最前面能答：Dart 在 runApp 之前就要据此决定画不画
    // 自绘标题栏与缩放热区。
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_bool(self->client_decorations)));
  } else if (g_strcmp0(method, "minimize") == 0) {
    gtk_window_iconify(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "toggleMaximize") == 0) {
    if (gtk_window_is_maximized(window)) {
      gtk_window_unmaximize(window);
    } else {
      gtk_window_maximize(window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "close") == 0) {
    gtk_window_close(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "isMaximized") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_bool(gtk_window_is_maximized(window))));
  } else if (g_strcmp0(method, "startDragging") == 0) {
    // 拖动必须由界面按下时触发：Flutter 视图覆盖整个窗口，GTK 收不到标题栏
    // 的按下事件，因此「让窗口管理器去识别拖动区」这条路在这里不成立。
    gint x = 0;
    gint y = 0;
    if (pointer_root_position(window, &x, &y)) {
      guint32 time = gtk_get_current_event_time();
      if (time == 0) {
        time = GDK_CURRENT_TIME;
      }
      // 这里要的是**按键编号**（1 = 左键），不是 GDK_BUTTON1_MASK 那类事件掩码；
      // 且 GTK3 里没有 GDK_BUTTON1 这个标识符（那是 GTK4 的写法）。
      gtk_window_begin_move_drag(window, 1, x, y, time);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "startResize") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    GdkWindowEdge edge;
    if (fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad_args", "startResize 需要一个边名", nullptr));
    } else if (!edge_from_name(fl_value_get_string(args), &edge)) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad_args", "未知的边名", nullptr));
    } else {
      gint x = 0;
      gint y = 0;
      if (pointer_root_position(window, &x, &y)) {
        guint32 time = gtk_get_current_event_time();
        if (time == 0) {
          time = GDK_CURRENT_TIME;
        }
        // 同上：这里要的是按键编号，不是掩码。
        gtk_window_begin_resize_drag(window, edge, 1, x, y, time);
      }
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (g_strcmp0(method, "setTrayState") == 0) {
    // 托盘状态由 Dart 在变化时推来（见 core/system_tray.dart），原生不轮询、
    // 也不自己查更新。
    apply_tray_state(self, fl_method_call_get_args(method_call));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "quitNow") == 0) {
    // Dart 已经收尾完成（还原系统代理、结束内核），可以真正退出了。
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    finish_quit(self);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

// 窗口状态变化时**主动**告诉 Dart。
//
// 与 Windows 端 WM_SIZE 那条推送同一个理由：最大化并不只发生在点按钮的时候。
// 双击标题栏、从任务栏还原、合成器的快捷键……Dart 侧完全不知情，标题栏按钮
// 会停在旧图标上——窗口已经最大化，它还画着「最大化」的方框。
static gboolean window_state_event_cb(GtkWidget* widget, GdkEvent* event,
                                      gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (event->type != GDK_WINDOW_STATE) {
    return FALSE;
  }
  GdkEventWindowState* state = reinterpret_cast<GdkEventWindowState*>(event);
  const gboolean maximized =
      (state->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
  if (maximized != self->last_maximized) {
    self->last_maximized = maximized;
    if (self->window_channel != nullptr) {
      g_autoptr(FlValue) args = fl_value_new_bool(maximized);
      fl_method_channel_invoke_method(self->window_channel, "maximizedChanged",
                                      args, nullptr, push_method_done,
                                      nullptr);
    }
  }
  return FALSE;
}

// 建立与 Dart 对接的窗口通道。
static void setup_window_channel(MyApplication* self, FlView* view,
                                 GtkWindow* window,
                                 gboolean client_decorations) {
  self->window = window;
  self->client_decorations = client_decorations;
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kPlatformChannel, FL_METHOD_CODEC(fl_standard_method_codec_new()));
  fl_method_channel_set_method_call_handler(
      self->window_channel, window_method_call_cb, self, nullptr);
  gtk_widget_add_events(GTK_WIDGET(window), GDK_STRUCTURE_MASK);
  g_signal_connect(window, "window-state-event",
                   G_CALLBACK(window_state_event_cb), self);
  // 关闭语义在原生侧决定：有托盘就收进托盘，没有就退出（见回调里的说明）。
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_event_cb),
                   self);
  self->last_maximized = gtk_window_is_maximized(window);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // 由会话类型决定窗口框谁来画。
  //
  //   * X11：去掉原生装饰，自绘标题栏（与 Windows 端一致的外观）。
  //   * Wayland：xdg_toplevel 不保证支持可编程的移动/缩放，
  //     gtk_window_begin_move_drag 在部分合成器上会无声失败。此时保留原生
  //     装饰，并把能力如实告诉 Dart，让界面收起自绘按钮与拖动区。
  //
  // 不做这个区分会得到一个「拖不动、点不响应」的死标题栏——比直接用系统
  // 标题栏更糟。
  gboolean client_decorations = TRUE;
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
#ifdef GDK_WINDOWING_WAYLAND
  if (display != nullptr && GDK_IS_WAYLAND_DISPLAY(display)) {
    client_decorations = FALSE;
  }
#endif

  gtk_window_set_title(window, "XVPN");
  // 与 Windows runner 一致：1180×742 画布 + 46 高的自绘标题栏。
  // Wayland 下没有自绘标题栏，同一数值会多出一条装饰的高度；窗口本就可
  // 调整大小，不值得为两种会话各写一组常量。
  gtk_window_set_default_size(window, 1180, 788);
  // 注意是**取反**：client_decorations 为真表示应用自绘，此时必须去掉原生
  // 装饰；Wayland 下为假，交回系统装饰。写反会得到一个完全没有边框的窗口。
  gtk_window_set_decorated(window, !client_decorations);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  // 插件注册之后再建通道。命令行参数（双击 .conf 打开）由
  // my_application_local_command_line 存进 dart_entrypoint_arguments，
  // 经由 project 传给 Dart，不经过本通道。
  setup_window_channel(self, view, window, client_decorations);

  gtk_widget_grab_focus(GTK_WIDGET(view));

  // 托盘在通道之后建：退出菜单项要把动作推回 Dart，得先有通道。
  setup_tray(self);
  // 注销 / 关机 / Ctrl+C 也走同一条「先收尾再退出」的路径，避免留下孤儿内核与
  // 指向死端口的系统代理（Windows 侧对应 WM_QUERYENDSESSION 那一段）。
  g_unix_signal_add(SIGTERM, terminate_signal_cb, self);
  g_unix_signal_add(SIGINT, terminate_signal_cb, self);
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  // 兜底超时如果不摘掉，它会在对象释放后以悬空的 self 被触发。
  if (self->quit_fallback_id != 0) {
    g_source_remove(self->quit_fallback_id);
    self->quit_fallback_id = 0;
  }
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  // 图标路径字符串是我们自己 g_strdup 的；indicator 与菜单由进程退出统一回收，
  // 不在这里动它们（拆 GObject 与 D-Bus 注销的顺序不值得在退出路径上冒险）。
  g_clear_pointer(&self->tray_icon_normal, g_free);
  g_clear_pointer(&self->tray_icon_grey, g_free);
  g_clear_pointer(&self->tray_status_text, g_free);
  // 窗口由 GtkApplication 持有，这里不 unref，只断开引用。
  self->window = nullptr;
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
