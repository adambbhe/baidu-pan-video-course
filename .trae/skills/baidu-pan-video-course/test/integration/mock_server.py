# -*- coding: utf-8 -*-
"""
Mock 百度网盘 Streaming 服务器
模拟 share/streaming 接口，返回 M3U8 播放列表和 TS 分片数据
"""
import http.server, socketserver, json, os, tempfile, struct, gzip, io, sys, re

PORT = 9876
SEGMENT_COUNT = 10          # 模拟 10 个分片
SEGMENT_SIZE = 1024 * 50    # 每个分片 50KB
SEGMENT_DURATION = 10       # 每分片 10 秒

class MockStreamingHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        parsed = self.path.split("?")[0]

        # /streaming — 返回 M3U8
        if "/streaming" in parsed:
            query = {}
            if "?" in self.path:
                for kv in self.path.split("?")[1].split("&"):
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        query[k] = v

            m3u8_type = query.get("type", "M3U8_AUTO_480")

            # 字幕接口
            if "SUBTITLE" in m3u8_type:
                self._serve_subtitles()
                return

            # M3U8 播放列表
            self._serve_m3u8()
            return

        # /segment/N — 返回 TS 分片数据
        m = re.match(r"/segment/(\d+)", parsed)
        if m:
            seg_idx = int(m.group(1))
            self._serve_segment(seg_idx)
            return

        # /health
        if "/health" in parsed:
            self._json_response({"status": "ok"})
            return

        self.send_error(404)

    def _serve_m3u8(self):
        """构造 M3U8 播放列表，每个分片指向 localhost mock 服务"""
        lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:10"]
        for i in range(SEGMENT_COUNT):
            lines.append(f"#EXTINF:{SEGMENT_DURATION},")
            lines.append(f"http://127.0.0.1:{PORT}/segment/{i}")
        # 模拟 baidupcs 格式的分片 URL（测试正则匹配）
        lines.append("#EXTINF:10,")
        # 加上 2 个 baidupcs 格式 URL 测试备用正则
        for j in range(2):
            lines.append(f"https://bdct06.baidupcs.com/video/mock_{j}_ts/etag?range={j*100}-{j*100+99}")
        lines.append("#EXT-X-ENDLIST")
        body = "\n".join(lines)

        # gzip 压缩（模拟百度响应）
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode='w') as f:
            f.write(body.encode())
        compressed = buf.getvalue()

        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.apple.mpegurl")
        self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", len(compressed))
        self.end_headers()
        self.wfile.write(compressed)

    def _serve_segment(self, idx):
        """生成模拟 TS 分片数据"""
        if idx < 0 or idx >= SEGMENT_COUNT:
            self.send_error(404)
            return

        # 生成伪 TS 数据（带 TS sync byte 0x47）
        data = bytearray()
        # TS 包：188 bytes each, sync byte 0x47
        num_packets = SEGMENT_SIZE // 188
        for _ in range(num_packets):
            pkt = bytearray(188)
            pkt[0] = 0x47  # TS sync byte
            # PID 填充为索引
            pkt[1] = (idx >> 8) & 0x1F
            pkt[2] = idx & 0xFF
            # 填充递增数据
            for b in range(4, 188):
                pkt[b] = (idx + b) & 0xFF
            data.extend(pkt)

        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Content-Length", len(data))
        self.end_headers()
        self.wfile.write(data)

    def _serve_subtitles(self):
        """返回模拟 SRT 字幕"""
        srt = """1
00:00:00,000 --> 00:00:04,000
百度网盘视频课程测试字幕

2
00:00:04,000 --> 00:00:08,000
这是模拟的AI字幕内容

3
00:00:08,000 --> 00:00:12,000
用于验证字幕下载流程

4
00:00:12,000 --> 00:00:16,000
字幕解析和SRT格式生成

5
00:00:16,000 --> 00:00:20,000
完整的端到端测试验证
"""
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", len(srt.encode('utf-8')))
        self.end_headers()
        self.wfile.write(srt.encode('utf-8'))

    def _json_response(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # 抑制日志


def start_server():
    server = socketserver.TCPServer(("127.0.0.1", PORT), MockStreamingHandler)
    server.timeout = 1
    print(f"MOCK_SERVER: started on http://127.0.0.1:{PORT}")
    return server


if __name__ == "__main__":
    server = start_server()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print("MOCK_SERVER: stopped")
