# -*- coding: utf-8 -*-
"""
在电脑上跑一遍 KoComic 插件的冒烟测试。

用 lupa 提供一个真的 Lua 运行时,stubs.lua 假装成 KOReader,
HTTP / 文件 / zip 这些活儿由这里的 PY.* 帮手用 Python 干 ——
所以网络请求是真的会发出去的,拿到的是拷贝漫画的真实数据。

    pip install lupa
    python test/run_test.py
"""

import base64
import io
import json
import os
import shutil
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from PIL import Image, ImageDraw, ImageFont
from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_DIR = os.path.join(os.path.dirname(HERE), "kocomic.koplugin")
TEST_DIR = os.path.join(HERE, "_run")
SSL_CTX = ssl._create_unverified_context()

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def _text(value):
    """Lua 传过来的字符串是 bytes,统一转回 str。"""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value


def to_lua(lua, value):
    """把 Python 的数据递归转成 Lua 能吃的东西(字符串一律转 bytes)。"""
    if isinstance(value, str):
        return value.encode("utf-8")
    if isinstance(value, dict):
        return lua.table_from({to_lua(lua, k): to_lua(lua, v) for k, v in value.items()})
    if isinstance(value, (list, tuple)):
        return lua.table_from([to_lua(lua, v) for v in value])
    return value


def build_helpers(lua):
    def http_request(method, url, headers, body):
        method = method.decode() if isinstance(method, bytes) else method
        url = url.decode() if isinstance(url, bytes) else url
        head = {}
        if headers is not None:
            for key, value in headers.items():
                key = key.decode() if isinstance(key, bytes) else str(key)
                value = value.decode() if isinstance(value, bytes) else str(value)
                head[key] = value
        request = urllib.request.Request(url, data=body, headers=head, method=method)
        try:
            with urllib.request.urlopen(request, timeout=20, context=SSL_CTX) as response:
                return response.status, response.read(), to_lua(lua, dict(response.headers))
        except urllib.error.HTTPError as err:
            return err.code, err.read(), to_lua(lua, {})
        except OSError as err:
            print("  [http] 失败:", type(err).__name__, err)
            return 0, b"", to_lua(lua, {})

    def json_decode(text):
        if isinstance(text, bytes):
            text = text.decode("utf-8", "replace")
        return to_lua(lua, json.loads(text))

    def json_encode(value):
        return json.dumps(value).encode()

    def url_escape(text):
        if isinstance(text, str):
            text = text.encode()
        return urllib.parse.quote(text, safe="").encode()

    def b64(text):
        if isinstance(text, str):
            text = text.encode()
        return base64.b64encode(text)

    def attributes(path, what=None):
        path = path.decode() if isinstance(path, bytes) else path
        what = what.decode() if isinstance(what, bytes) else what
        try:
            stat = os.stat(path)
        except OSError:
            return None
        mode = "directory" if os.path.isdir(path) else "file"
        if what == "size":
            return stat.st_size
        if what == "mode":
            return mode.encode()
        return to_lua(lua, {"size": stat.st_size, "mode": mode})

    def list_dir(path):
        path = path.decode() if isinstance(path, bytes) else path
        try:
            names = [".", ".."] + sorted(os.listdir(path))
        except OSError:
            return None
        return to_lua(lua, names)

    def makedirs(path):
        path = path.decode() if isinstance(path, bytes) else path
        os.makedirs(path, exist_ok=True)
        return True

    def exists(path):
        path = path.decode() if isinstance(path, bytes) else path
        return os.path.exists(path)

    def purge_dir(path):
        path = path.decode() if isinstance(path, bytes) else path
        shutil.rmtree(path, ignore_errors=True)
        return True

    def zip_write(path, entries):
        path = path.decode() if isinstance(path, bytes) else path
        with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as archive:
            for _, entry in entries.items():
                name, data = entry[1], entry[2]
                if isinstance(name, bytes):
                    name = name.decode("utf-8", "replace")
                archive.writestr(name, data)
        return True

    def test_dir():
        return TEST_DIR.replace("\\", "/").encode()

    # Windows 的 C 运行时按 ANSI 解释文件名,中文路径会挂;真机上是 Linux,没这问题。
    def needs_wide_path(path):
        return isinstance(path, bytes) and any(byte > 127 for byte in path)

    def rename(source, target):
        try:
            os.replace(_text(source), _text(target))
            return True
        except OSError:
            return None

    def remove(path):
        try:
            os.remove(_text(path))
            return True
        except OSError:
            return None

    def open_file(path, mode):
        mode = _text(mode) or "r"
        try:
            handle = open(_text(path), mode)
        except OSError:
            return None

        def read(_self, _format=None):
            data = handle.read()
            return data if isinstance(data, bytes) else data.encode()

        def write(_self, chunk):
            handle.write(chunk)
            return True

        def close(_self):
            handle.close()
            return True

        return lua.table_from({b"read": read, b"write": write, b"close": close})

    # —————————————— 图像(顶替真机的 FFI 那层)——————————————
    images = {}
    next_id = [0]

    def _put(image):
        next_id[0] += 1
        images[next_id[0]] = image
        return next_id[0], image.width, image.height

    def img_decode(data, scale_w=None):
        try:
            image = Image.open(io.BytesIO(data)).convert("L")
        except Exception as err:
            print("  [img] 解码失败:", err)
            return None, 0, 0
        if scale_w and image.width != scale_w:
            height = max(1, round(image.height * scale_w / image.width))
            image = image.resize((int(scale_w), height), Image.LANCZOS)
        return _put(image)

    def img_new(width, height):
        return _put(Image.new("L", (int(width), int(height)), 255))[0]

    def img_scale(handle, width, height):
        return _put(images[handle].resize((int(width), int(height)), Image.LANCZOS))

    def img_blit(dst, src, dest_x, dest_y, src_x, src_y, width, height):
        source = images[src].crop((int(src_x), int(src_y),
                                   int(src_x) + int(width), int(src_y) + int(height)))
        images[dst].paste(source, (int(dest_x), int(dest_y)))
        return True

    def img_white(handle, x, y, width, height):
        image = images[handle]
        box = (int(x), int(y), min(image.width, int(x) + int(width)),
               min(image.height, int(y) + int(height)))
        if box[2] > box[0] and box[3] > box[1]:
            image.paste(255, box)
        return True

    def img_row_ink(handle, y, step):
        image = images[handle]
        y = int(y)
        if y < 0 or y >= image.height:
            return 0.0
        row = image.crop((0, y, image.width, y + 1)).tobytes()
        step = max(1, int(step))
        sample = row[::step]
        if not sample:
            return 0.0
        return sum(1 for v in sample if v < 224) / len(sample)

    def img_row_sample(handle, y, count):
        image = images[handle]
        y = max(0, min(int(y), image.height - 1))
        row = image.crop((0, y, image.width, y + 1)).tobytes()
        count = int(count)
        values = [row[min(len(row) - 1, i * (len(row) - 1) // max(1, count - 1))]
                  for i in range(count)]
        return lua.table_from(values)

    def img_histogram(handle, step):
        return lua.table_from(images[handle].histogram())

    def img_apply_lut(handle, lut):
        table_ = [int(lut[i + 1]) for i in range(256)]
        images[handle] = images[handle].point(table_)
        return True

    def img_fill(handle, x, y, width, height, value):
        image = images[handle]
        box = (int(x), int(y), min(image.width, int(x) + int(width)),
               min(image.height, int(y) + int(height)))
        if box[2] > box[0] and box[3] > box[1]:
            image.paste(int(value), box)
        return True

    def img_save_png(handle, path):
        images[handle].save(_text(path), "PNG")
        return True

    font_cache = {}

    def _font(size):
        size = int(size)
        if size not in font_cache:
            for path in ("C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simsun.ttc",
                         "C:/Windows/Fonts/arial.ttf"):
                try:
                    font_cache[size] = ImageFont.truetype(path, size)
                    break
                except OSError:
                    continue
            else:
                font_cache[size] = ImageFont.load_default()
        return font_cache[size]

    def _wrap(text, size, width):
        font = _font(size)
        lines, current = [], ""
        for char in text:
            if char == chr(10):
                lines.append(current)
                current = ""
                continue
            trial = current + char
            if font.getlength(trial) > width and current:
                lines.append(current)
                current = char
            else:
                current = trial
        if current:
            lines.append(current)
        return lines or [""], font

    def img_text_size(text, size, width):
        lines, _ = _wrap(_text(text), size, width)
        return len(lines) * int(int(size) * 1.35)

    def img_text(handle, x, y, text, size, width):
        image = images[handle]
        draw = ImageDraw.Draw(image)
        lines, font = _wrap(_text(text), size, width)
        line_h = int(int(size) * 1.35)
        for i, line in enumerate(lines):
            draw.text((int(x), int(y) + i * line_h), line, font=font, fill=0)
        return True

    def img_save(handle, path, quality):
        images[handle].save(_text(path), "JPEG", quality=int(quality))
        return True

    def img_free(handle):
        images.pop(handle, None)
        return True

    def test_dir_src():
        return HERE.replace("\\", "/").encode()

    return lua.table_from({
        b"img_decode": img_decode,
        b"img_new": img_new,
        b"img_scale": img_scale,
        b"img_blit": img_blit,
        b"img_white": img_white,
        b"img_row_ink": img_row_ink,
        b"img_row_sample": img_row_sample,
        b"img_histogram": img_histogram,
        b"img_apply_lut": img_apply_lut,
        b"img_fill": img_fill,
        b"img_save_png": img_save_png,
        b"img_text": img_text,
        b"img_text_size": img_text_size,
        b"img_save": img_save,
        b"img_free": img_free,
        b"test_dir_src": test_dir_src,
        b"needs_wide_path": needs_wide_path,
        b"rename": rename,
        b"remove": remove,
        b"open_file": open_file,
        b"http_request": http_request,
        b"json_decode": json_decode,
        b"json_encode": json_encode,
        b"url_escape": url_escape,
        b"b64": b64,
        b"attributes": attributes,
        b"list_dir": list_dir,
        b"makedirs": makedirs,
        b"exists": exists,
        b"purge_dir": purge_dir,
        b"zip_write": zip_write,
        b"test_dir": test_dir,
    })


def main():
    shutil.rmtree(TEST_DIR, ignore_errors=True)
    os.makedirs(os.path.join(TEST_DIR, "settings"), exist_ok=True)

    lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
    globals_ = lua.globals()
    globals_[b"PY"] = build_helpers(lua)
    lua.execute(("package.path = '%s/?.lua;%s/?.lua;' .. package.path"
                 % (PLUGIN_DIR.replace("\\", "/"), HERE.replace("\\", "/"))).encode())
    lua.execute(b"require('stubs')")

    name = sys.argv[1] if len(sys.argv) > 1 else "scenario.lua"
    scenario = open(os.path.join(HERE, name), "rb").read()
    ok = lua.execute(scenario)

    cbz_files = []
    for root, _dirs, files in os.walk(TEST_DIR):
        for name in files:
            if name.endswith(".cbz"):
                cbz_files.append(os.path.join(root, name))
    print("\n=== 生成的 CBZ ===")
    sample_dir = os.path.join(HERE, "_pages")
    os.makedirs(sample_dir, exist_ok=True)
    screen = (1264, 1680)
    for path in cbz_files:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            sizes = []
            for name in names:
                with archive.open(name) as handle:
                    sizes.append(Image.open(io.BytesIO(handle.read())).size)
            # 挑一页存成 PNG,可以直接用眼睛看裁得对不对
            for pick in (names[:2] + names[-2:]):
                with archive.open(pick) as handle:
                    Image.open(io.BytesIO(handle.read())).save(os.path.join(
                        sample_dir, "%s-%s.png" % (os.path.basename(path)[:20], pick.replace("/", "_"))))
        unique = sorted(set(sizes))
        shown = ", ".join("%dx%d" % s for s in unique[:4]) + (" …" if len(unique) > 4 else "")
        print("  %s" % os.path.basename(path))
        print("     %d 页,尺寸 %s" % (len(names), shown))
        if unique == [screen]:
            print("     ✓ 每页正好一屏 %dx%d,KOReader 打开即满屏一页" % screen)
    if not cbz_files:
        print("  (没有)")
        return 1
    return 0 if ok is not False else 1


if __name__ == "__main__":
    sys.exit(main())
