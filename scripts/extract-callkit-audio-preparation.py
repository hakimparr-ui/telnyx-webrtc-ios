import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / "TelnyxRTC/Telnyx/TxClient.swift").read_text()
signature = "public func prepareAudioSessionForCallKit() throws {"
if source.count(signature) != 1:
    raise SystemExit("Expected exactly one CallKit preparation implementation")
start = source.index(signature)
body = source.index("{", start)
depth = 1
end = body + 1
while end < len(source) and depth:
    if source[end] == "{":
        depth += 1
    elif source[end] == "}":
        depth -= 1
    end += 1
if depth:
    raise SystemExit("CallKit preparation body is incomplete")
fixture = (root / "scripts/callkit-audio-preparation-fixture.swift").read_text()
marker = "__ACTUAL_PREPARATION_METHOD__"
if fixture.count(marker) != 1:
    raise SystemExit("Expected exactly one extraction marker")
sys.stdout.write(fixture.replace(marker, source[start:end]))
