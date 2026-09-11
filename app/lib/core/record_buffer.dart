/// 大数据量下仍然无抖动的两个基础容器。
///
/// 分流记录页与连接去重各自踩过同一个坑：用 `List.insert(0, x)` + `removeRange`
/// 维护「最近 N 条」，看起来只动首尾，实际每次插入都要把整段内存往后搬一格。
/// 连接数上千、内核每秒推一次快照时，这部分开销会在每帧的构建里累积成掉帧。
///
/// 这里用固定容量的环形缓冲把「插入」变成 O(1) 的写指针移动，
/// 对外仍然按「最新的在最前面」的顺序枚举，调用方不需要知道内部结构。
library;

/// 固定容量、最新的元素在前的环形缓冲。
///
/// 容量写满后每插入一条就丢弃最旧的一条，不会增长、不会扩容、不产生垃圾。
class RingBuffer<T> {
  RingBuffer(this.capacity)
      : assert(capacity > 0, '容量必须为正数'),
        _slots = List<T?>.filled(capacity, null);

  /// 最多保留的元素个数。
  final int capacity;

  final List<T?> _slots;

  /// 下一个写入位置。写入时先自减，因此「最新的元素」永远紧邻 _next 之前，
  /// 枚举顺序天然就是「新的在前」。
  int _next = 0;

  int _length = 0;

  int get length => _length;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length != 0;

  /// 压入一条最新记录。满了就覆盖最旧的那条。
  void push(T value) {
    _next = (_next - 1) % capacity;
    if (_next < 0) _next += capacity;
    _slots[_next] = value;
    if (_length < capacity) _length++;
  }

  /// 按「新的在前」的顺序取第 [index] 条。[index] 越界返回 null。
  T? operator [](int index) {
    if (index < 0 || index >= _length) return null;
    return _slots[(_next + index) % capacity];
  }

  /// 按「新的在前」的顺序枚举。直接读内部槽位，不复制列表。
  Iterable<T> get values sync* {
    for (var i = 0; i < _length; i++) {
      yield _slots[(_next + i) % capacity] as T;
    }
  }

  void clear() {
    // 先清引用再重置指针：否则被丢弃的对象会被缓冲一直持有，
    // 在记录里带着域名这种较长的字符串时表现为持续的内存占用。
    for (var i = 0; i < capacity; i++) {
      _slots[i] = null;
    }
    _next = 0;
    _length = 0;
  }
}

/// 有容量上限的「见过」集合：满了淘汰最旧的一条。
///
/// 这里修的是一个会直接影响用户可见正确性的问题。原实现是：
///
/// ```dart
/// if (_seenConnections.length > 2000) _seenConnections.clear();
/// ```
///
/// 一旦连接数超过上限就整体清空，于是**当前活着的每一条连接都会被当成新连接**
/// 重新上报一遍，分流记录里立刻出现成片的重复条目；而清空之后长度回到 0，
/// 很快又长到 2000，如此循环。换成按插入顺序淘汰以后，容量恒定、
/// 已上报过的连接不会被重复上报。
class BoundedIdSet {
  BoundedIdSet(this.capacity)
      : assert(capacity > 0, '容量必须为正数'),
        _order = List<String?>.filled(capacity, null);

  /// 容量上限。会在运行中按需增长，见 [_grow]。
  int capacity;

  /// 自动增长的上限。到这个规模就不再涨了。
  ///
  /// 4000 是在「够用」与「别占内存」之间取的数：稳态下内核里的活连接通常在
  /// 几百条量级，4000 留了一个数量级的余量；而每条只是一个 36 字节的 UUID
  /// 字符串，即使全部占满也只有几百 KB。
  ///
  /// 可变是为了让测试能把增长关掉，专门验证「淘汰最旧」这条路径。
  int growthCeiling = defaultGrowthCeiling;

  static const int defaultGrowthCeiling = 4000;

  final Set<String> _members = <String>{};

  /// 固定容量的环形存储。写入位置与 [`capacity`] 一起构成环，
  /// 因此每次扩容都必须整体重建，不能只 append。
  List<String?> _order;

  /// 下一个写入位置。
  int _next = 0;

  /// 已写入的条数，上限为 [capacity]。
  int _count = 0;

  int get length => _members.length;

  bool contains(String id) => _members.contains(id);

  /// 记录一个 id。已存在时返回 false（调用方据此跳过重复上报）。
  bool add(String id) {
    if (!_members.add(id)) return false;

    if (_count < capacity) {
      _order[(_next + _count) % capacity] = id;
      _count++;
      return true;
    }

    // 满了：先考虑扩容量。
    //
    // 这一步是必要的，不是「优化」。容量固定时存在一个会持续抖动的死循环：
    // 活连接数稳定超过容量 → 每轮都有若干条连接被挤出集合 → 下一轮它们
    // 又被当成新连接上报。表现出来就是分流记录里每隔几秒出现一批重复条目，
    // 而这类重复正是原实现（超过阈值就整体清空）最严重的问题。
    // 按实际规模扩容之后，稳态下集合能装下全部活连接，重复自然消失。
    if (_grow()) {
      _order[(_next + _count) % capacity] = id;
      _count++;
      return true;
    }

    // 已经到上限：用新 id 覆盖最旧的位置，并把最旧的从集合里摘掉。
    final evicted = _order[_next];
    if (evicted != null) _members.remove(evicted);
    _order[_next] = id;
    _next = (_next + 1) % capacity;
    return true;
  }

  /// 容量不够时翻倍并重建环形存储。返回是否扩容成功。
  bool _grow() {
    if (_count < capacity) return true;
    if (capacity >= growthCeiling) return false;
    final next = capacity * 2 > growthCeiling ? growthCeiling : capacity * 2;
    if (next <= capacity) return false;
    final rebuilt = List<String?>.filled(next, null);
    // 按「最旧 → 最新」的顺序搬到新环里，写指针回到 0。
    for (var i = 0; i < _count; i++) {
      rebuilt[i] = _order[(_next + i) % capacity];
    }
    _order = rebuilt;
    capacity = next;
    _next = 0;
    return true;
  }

  bool addAll(Iterable<String> ids) {
    var changed = false;
    for (final id in ids) {
      if (add(id)) changed = true;
    }
    return changed;
  }

  void clear() {
    _members.clear();
    for (var i = 0; i < _order.length; i++) {
      _order[i] = null;
    }
    _next = 0;
    _count = 0;
  }
}
