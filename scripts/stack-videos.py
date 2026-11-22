#!/usr/bin/env python3
"""Stack headed-run videos one above the other, in step by game time, to compare camera versions.

    stack-videos.py out.mp4 top.mp4 "Top label" bottom.mp4 "Bottom label" [...]

The videos must be recorded with SYNC=1 (see run-replay-headed.sh), which draws the game frame as a
strip of squares in the bottom left corner (rc_frameclock.lua). Each output frame is one game frame
(30 a second): every video shows the last frame it recorded at or before that game frame, so
differing start-up times and engine stalls don't put them out of step. The strip is cropped off and
each video gets its label. Output runs from the latest start to the earliest end.

Needs GStreamer with its Python bindings (gi), and numpy and Pillow.
"""
import sys

import gi
import numpy as np
from PIL import Image, ImageDraw, ImageFont

gi.require_version('Gst', '1.0')
from gi.repository import Gst  # noqa: E402

FPS = 30
CELL, BITS = 8, 16  # as in rc_frameclock.lua
CROP = CELL
QUALITY = 21


class Reader:
    """Decoded I420 frames of a video, with the game frame each shows (None when it shows none)."""

    def __init__(self, path):
        self.pipeline = Gst.parse_launch(
            f'filesrc location="{path}" ! qtdemux ! h264parse ! avdec_h264 ! videoconvert '
            '! video/x-raw,format=I420 ! appsink name=sink sync=false max-buffers=16')
        self.sink = self.pipeline.get_by_name('sink')
        self.pipeline.set_state(Gst.State.PLAYING)
        self.width = self.height = None

    def next(self):
        sample = self.sink.emit('pull-sample')
        if sample is None:
            return None
        s = sample.get_caps().get_structure(0)
        self.width, self.height = s.get_value('width'), s.get_value('height')
        buf = sample.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        data = np.frombuffer(info.data, dtype=np.uint8).copy()
        buf.unmap(info)
        w, h = self.width, self.height
        y = data[:w * h].reshape(h, w)
        u = data[w * h:w * h + w * h // 4].reshape(h // 2, w // 2)
        v = data[w * h + w * h // 4:w * h * 3 // 2].reshape(h // 2, w // 2)
        return frame_code(y), (y, u, v)

    def close(self):
        self.pipeline.set_state(Gst.State.NULL)


def frame_code(y):
    row = y[-CELL // 2]
    cells = [row[i * CELL + CELL // 2] > 128 for i in range(BITS + 2)]
    if not cells[0] or cells[1]:
        return None
    return sum(1 << i for i, on in enumerate(cells[2:]) if on)


def label_mask(text, width):
    """White text on a black box, as luma, and where the box is."""
    font = None
    for name in ('DejaVuSans-Bold.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'):
        try:
            font = ImageFont.truetype(name, 26)
            break
        except OSError:
            pass
    font = font or ImageFont.load_default()
    box = ImageDraw.Draw(Image.new('L', (1, 1))).textbbox((0, 0), text, font=font)
    w, h = min(width, box[2] - box[0] + 24), box[3] - box[1] + 16
    im = Image.new('L', (w + w % 2, h + h % 2), 16)
    ImageDraw.Draw(im).text((12 - box[0], 8 - box[1]), text, fill=235, font=font)
    return np.asarray(im)


def main():
    if len(sys.argv) < 6 or len(sys.argv) % 2:
        sys.exit(__doc__)
    Gst.init(None)
    out = sys.argv[1]
    pairs = list(zip(sys.argv[2::2], sys.argv[3::2]))
    readers = [Reader(path) for path, _ in pairs]

    # Each reader's current frame (last at or before the game frame) and the one after it
    current, ahead = [None] * len(readers), [None] * len(readers)
    for i, r in enumerate(readers):
        while True:
            item = r.next()
            if item is None:
                sys.exit(f'{pairs[i][0]}: no game frame strip found; record with SYNC=1')
            if item[0] is not None:
                ahead[i] = item
                break
    start = max(a[0] for a in ahead)
    width, height = readers[0].width, readers[0].height
    if any((r.width, r.height) != (width, height) for r in readers):
        sys.exit('videos differ in size')
    tile_h = height - CROP
    labels = [label_mask(text, width) for _, text in pairs]

    def advance(i, game_frame):
        """Move reader i on to its last frame at or before game_frame; False once it has run out."""
        while ahead[i] is not None and (ahead[i][0] is None or ahead[i][0] <= game_frame):
            if ahead[i][0] is not None:
                current[i] = ahead[i]
            ahead[i] = readers[i].next()
        return ahead[i] is not None or current[i] is not None and current[i][0] >= game_frame

    out_h = tile_h * len(readers)
    enc = Gst.parse_launch(
        # Blocks when the encoder is behind, rather than queueing frames (4MB each) until memory runs out
        f'appsrc name=src format=time block=true max-bytes={64 << 20} caps=video/x-raw,format=I420,width={width},height={out_h},framerate={FPS}/1 '
        f'! x264enc speed-preset=medium pass=qual quantizer={QUALITY} key-int-max={FPS * 5} '
        f'! h264parse ! mp4mux ! filesink location="{out}"')
    src = enc.get_by_name('src')
    enc.set_state(Gst.State.PLAYING)

    game_frame, n = start, 0
    while all(advance(i, game_frame) for i in range(len(readers))):
        ys, us, vs = [], [], []
        for (_, (y, u, v)), label in zip(current, labels):
            y, u, v = y[:tile_h].copy(), u[:tile_h // 2].copy(), v[:tile_h // 2].copy()
            lh, lw = label.shape
            top = tile_h - lh - 8
            y[top:top + lh, 8:8 + lw] = label
            u[top // 2:(top + lh) // 2, 4:4 + lw // 2] = 128
            v[top // 2:(top + lh) // 2, 4:4 + lw // 2] = 128
            ys.append(y), us.append(u), vs.append(v)
        data = b''.join(np.concatenate(planes).tobytes() for planes in (ys, us, vs))
        buf = Gst.Buffer.new_wrapped(data)
        buf.pts = n * Gst.SECOND // FPS
        buf.duration = Gst.SECOND // FPS
        src.emit('push-buffer', buf)
        game_frame, n = game_frame + 1, n + 1
        if n % (FPS * 60) == 0:
            print(f'{n // (FPS * 60)} min', flush=True)

    src.emit('end-of-stream')
    enc.get_bus().timed_pop_filtered(Gst.CLOCK_TIME_NONE, Gst.MessageType.EOS | Gst.MessageType.ERROR)
    enc.set_state(Gst.State.NULL)
    for r in readers:
        r.close()
    print(f'{out}: game frames {start} to {game_frame - 1}, {n / FPS:.0f}s')


if __name__ == '__main__':
    main()
