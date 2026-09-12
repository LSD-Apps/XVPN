#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
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

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* window_channel;
  GtkWindow* window;
  // 本会话是否由应用自绘窗口框。X11 为 TRUE，Wayland 为 FALSE。
  gboolean client_decorations;
  gboolean last_maximized;
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
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
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
