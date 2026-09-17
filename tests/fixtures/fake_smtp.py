#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""受入テスト用の最小 SMTP サーバー（ループバック限定・平文）。

受け取ったメールを 1 通ずつ --out のディレクトリへ書き出す。
本番では使わない。scripts/send_mail_outbox.py が実際に SMTP 会話を通せて、
送信後に app.mail_outbox と質問票の状態が進むことを確かめるためだけのもの。
"""
from __future__ import annotations

import argparse
import pathlib
import socket
import threading

def handle(conn: socket.socket, out_dir: pathlib.Path, counter: list[int]) -> None:
    stream = conn.makefile('rwb')

    def send(line: str) -> None:
        stream.write((line + '\r\n').encode())
        stream.flush()

    send('220 fake-smtp ready')
    while True:
        raw = stream.readline()
        if not raw:
            return
        command = raw.decode('utf-8', 'replace').strip()
        upper = command.upper()
        if upper.startswith('EHLO') or upper.startswith('HELO'):
            send('250-fake-smtp')
            send('250 AUTH LOGIN PLAIN')
        elif upper.startswith('AUTH'):
            # LOGIN はユーザー名・パスワードを 2 往復で受ける。中身は見ない。
            if upper.startswith('AUTH LOGIN') and len(command.split()) == 2:
                send('334 VXNlcm5hbWU6')
                stream.readline()
                send('334 UGFzc3dvcmQ6')
                stream.readline()
            send('235 authenticated')
        elif upper.startswith('MAIL FROM') or upper.startswith('RCPT TO'):
            send('250 ok')
        elif upper == 'DATA':
            send('354 end with .')
            body: list[bytes] = []
            while True:
                line = stream.readline()
                if not line or line.strip() == b'.':
                    break
                body.append(line)
            counter[0] += 1
            (out_dir / f'mail-{counter[0]}.eml').write_bytes(b''.join(body))
            send('250 queued')
        elif upper == 'QUIT':
            send('221 bye')
            return
        elif upper == 'RSET':
            send('250 ok')
        else:
            send('250 ok')


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--expect', type=int, default=1, help='この通数を受け取ったら終了する')
    args = parser.parse_args()
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    counter = [0]
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', args.port))
    server.listen(8)
    server.settimeout(30)
    while counter[0] < args.expect:
        try:
            conn, _ = server.accept()
        except socket.timeout:
            break
        thread = threading.Thread(target=handle, args=(conn, out_dir, counter), daemon=True)
        thread.start()
        thread.join(30)
        conn.close()
    server.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
