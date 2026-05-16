import re
from PIL import Image
import os

with open("firmware/src/codex_icon.h") as f:
    text = f.read()

array_text = text.split("{")[1].split("}")[0]
hex_vals = re.findall(r"0x([0-9A-Fa-f]{4})", array_text)

img = Image.new("RGBA", (32, 32))
pixels = img.load()
trans_color = 0xF81F

for i, h in enumerate(hex_vals):
    val = int(h, 16)
    x = i % 32
    y = i // 32
    if val == trans_color:
        img.putpixel((x, y), (0, 0, 0, 0))
    else:
        # RGB565 to RGB888
        r = (val >> 11) & 0x1F
        g = (val >> 5) & 0x3F
        b = val & 0x1F
        r = (r << 3) | (r >> 2)
        g = (g << 2) | (g >> 4)
        b = (b << 3) | (b >> 2)
        img.putpixel((x, y), (r, g, b, 255))

os.makedirs("ios/CodexMeterApp/Assets.xcassets/CodexIcon.imageset", exist_ok=True)
img.resize((128, 128), Image.Resampling.NEAREST).save(
    "ios/CodexMeterApp/Assets.xcassets/CodexIcon.imageset/CodexIcon.png"
)

with open(
    "ios/CodexMeterApp/Assets.xcassets/CodexIcon.imageset/Contents.json", "w"
) as f:
    f.write("""{
  "images" : [
    {
      "idiom" : "universal",
      "filename" : "CodexIcon.png",
      "scale" : "1x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}""")
print("Icon extracted and saved.")
