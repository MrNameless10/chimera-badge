import base64
import sys


def build(template, atlas, out):
    with open(atlas, "rb") as f:
        data = base64.b64encode(f.read()).decode()
    with open(template, encoding="utf-8") as f:
        page = f.read()
    with open(out, "w", encoding="utf-8") as f:
        f.write(page.replace("__ATLAS__", data, 1))


if __name__ == "__main__":
    build(*sys.argv[1:4])
