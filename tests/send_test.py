#!/usr/bin/env python3
"""往收包端探针发状态包，顺便校验它的回执。用的是辅助程序里真实的 ipc.py。

用法: python3 tests/send_test.py [秒数] [端口]
故意跳几个 seq，看对方数出来的 lost 对不对。
"""
import socket
import sys
import time
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'Endfield-FpvHelper'))
from fpvhelper import ipc


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 4.0
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 47800
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1', 0))
    sock.setblocking(False)
    target = ('127.0.0.1', port)
    seq = 0
    sent = 0
    skipped = 0
    replies = 0
    statuses = []
    start = time.time()
    next_report = start + 1.0
    t0 = time.time()
    while time.time() - start < seconds:
        now = time.time()
        tick = (now - t0) * 60                      # 假装 60 Hz
        if 1.5 <= now - start < 2.5:                # 定值阶段：探针每秒打一次源码，对得上就说明整条线没错
            roll, pitch, yaw, throttle = -1234, 567, 8910, 1000
            switches, buttons, aux = 5, 7, 9
            flags = ipc.ST_VALID | ipc.ST_ARMED | ipc.ST_HOLD
        else:
            roll = int(120 * __import__('math').sin(tick * 0.2))
            pitch = int(60 * __import__('math').sin(tick * 0.11))
            yaw = int(90 * __import__('math').cos(tick * 0.13))
            throttle = int(500 + 400 * __import__('math').sin(tick * 0.07))
            switches, buttons, aux = 1, 0, 0
            flags = ipc.ST_VALID | ipc.ST_ARMED
        seq = (seq + 1) & 0xFFFF
        if sent in (30, 60):                        # 故意各漏两号，看它数不数得出来
            seq = (seq + 2) & 0xFFFF
            skipped += 2
        sock.sendto(ipc.pack_state(seq, int((now - start) * 1000), roll, pitch, yaw, throttle,
                                   switches=switches, buttons=buttons, aux=aux, flags=flags), target)
        sent += 1
        try:
            while True:
                data, _ = sock.recvfrom(256)
                status = ipc.unpack_status(data)
                if status:
                    replies += 1
                    statuses.append((status, now - start))
                elif data:
                    print('收到解不开的包:', data[:16].hex())
        except BlockingIOError:
            pass
        if now >= next_report:
            next_report = now + 1.0
            print(f'  发送 {sent} 包，收到回执 {replies} 个')
        # 按 250 Hz 控速：下一包的发送时刻是固定的，晚点就追回来，早到就等到点
        due = start + sent / 250.0
        gap = due - time.time()
        if gap > 0:
            time.sleep(gap)
    # 收尾：假装辅助程序重启（seq 归零），缺号数不应该因此暴涨
    for i in range(5):
        sock.sendto(ipc.pack_state(i, 0, 0, 0, 0, 0, flags=ipc.ST_VALID), target)
        time.sleep(0.02)
    try:
        while True:
            data, _ = sock.recvfrom(256)
            status = ipc.unpack_status(data)
            if status:
                replies += 1
                statuses.append((status, 0.0))
    except BlockingIOError:
        pass
    print(f'总共发送 {sent} 包（故意漏号 {skipped}），收到回执 {replies} 个，发送名义频率 250 Hz')
    if statuses:
        st, at = statuses[-1]
        print('最后一条回执:', st, f'（在 {at:.2f}s）')
        print('flags 解码:',
              '接收端在跑' if st['flags'] & ipc.SG_RUNNING else '没跑',
              '| 相机已接管' if st['flags'] & ipc.SG_TAKEOVER else '| 没接管',
              '| 要求复位' if st['flags'] & ipc.SG_WANT_RESET else '')
        print('它数出来的缺号:', st['lost'], '（我们故意漏了', skipped, '）',
              '| 它报的游戏侧帧率:', st['fps'])


if __name__ == '__main__':
    main()
