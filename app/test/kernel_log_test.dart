import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/kernel_log.dart';

void main() {
  group('内核日志缓冲', () {
    test('按容量丢弃最旧的，并如实记账', () {
      final log = KernelLogBuffer(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        log.add('第 $i 行');
      }

      expect(log.lines, <String>['第 3 行', '第 4 行', '第 5 行']);
      expect(
        log.droppedLines,
        2,
        reason: '悄悄丢掉早期日志会让用户以为「日志就这么长」，从而误判问题发生的时间点',
      );
      expect(log.lastLine, '第 5 行');
    });

    test('空行与纯空白不记录', () {
      final log = KernelLogBuffer();
      log.add('');
      log.add('   ');
      log.add('\t');
      expect(log.lines, isEmpty);
      expect(log.isEmpty, isTrue);
    });

    test('行首尾空白被去掉', () {
      final log = KernelLogBuffer();
      log.add('  WARN something  \r');
      expect(log.lines, <String>['WARN something']);
    });
  });

  group('按块到达的输出', () {
    test('一块里的多行被拆开，末尾半行先留住', () {
      final log = KernelLogBuffer();
      final fresh = log.addChunk('第一行\n第二行\n半截');

      expect(fresh, <String>['第一行', '第二行']);
      expect(log.lines, <String>['第一行', '第二行'], reason: '没结束的那一行还不算完整行');
      expect(log.isEmpty, isFalse, reason: '待续区有内容，就不算空');
    });

    test('被切断的行会跨块拼回来', () {
      // 这是这一层存在的主要理由：stdout 的分块是任意的，一行完全可能被切成两半，
      // 而崩溃前的那一行，经常就是被切断的那一行。原实现直接按 \n 切分，
      // 于是产出一堆半截行。
      final log = KernelLogBuffer();
      log.addChunk('WARN failed to ');
      final fresh = log.addChunk('connect: timeout\n');

      expect(fresh, <String>['WARN failed to connect: timeout']);
      expect(log.lines, <String>['WARN failed to connect: timeout']);
    });

    test('一次到达三行半时，只交出两行', () {
      final log = KernelLogBuffer();
      final fresh = log.addChunk('a\nb\nc\n未完');
      expect(fresh, <String>['a', 'b', 'c']);
      expect(log.lines, hasLength(3));
    });

    test('没有换行的整块内容不会立刻成为一行', () {
      final log = KernelLogBuffer();
      expect(log.addChunk('还没有换行符'), isEmpty);
      expect(log.lines, isEmpty);
    });

    test('flushPending 把最后半行收下', () {
      // 进程退出时最后一行往往没有换行符结尾，而它经常正是崩溃原因。
      final log = KernelLogBuffer();
      log.addChunk('启动中\n崩溃原因在这里');
      expect(log.lines, <String>['启动中']);

      log.flushPending();
      expect(log.lines, <String>['启动中', '崩溃原因在这里']);
      expect(log.lastLine, '崩溃原因在这里');

      // 再调一次不会重复添加。
      log.flushPending();
      expect(log.lines, hasLength(2));
    });

    test('flushPending 不会把空白尾巴变成一行', () {
      final log = KernelLogBuffer();
      log.addChunk('只有这一行\n   ');
      log.flushPending();
      expect(log.lines, <String>['只有这一行']);
    });

    test('跨块拼接同样受容量限制', () {
      final log = KernelLogBuffer(capacity: 2);
      log.addChunk('a\nb\nc\n');
      expect(log.lines, <String>['b', 'c']);
      expect(log.droppedLines, 1);
    });
  });

  group('导出与清空', () {
    test('导出为纯文本，行之间一个换行', () {
      final log = KernelLogBuffer();
      log.addChunk('a\nb\nc\n');
      expect(log.asText(), 'a\nb\nc');
    });

    test('清空会连丢弃计数与待续区一起重置', () {
      final log = KernelLogBuffer(capacity: 1);
      log.addChunk('a\nb\n半截');
      expect(log.droppedLines, 1);

      log.clear();

      expect(log.lines, isEmpty);
      expect(log.droppedLines, 0);
      expect(log.lastLine, isNull);
      expect(log.isEmpty, isTrue, reason: '待续区也要清掉，否则下一块会拼到上一轮的尾巴上');
    });
  });

  group('对外暴露的视图不可被外部改动', () {
    test('lines 是只读快照', () {
      final log = KernelLogBuffer();
      log.add('a');
      expect(
        () => log.lines.add('b'),
        throwsUnsupportedError,
        reason: '外部直接改内部列表会让容量控制失效',
      );
    });
  });
}
