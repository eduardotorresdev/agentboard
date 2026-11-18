# Builds the post-it handwriting (Sources/AgentBoard/Resources/BoardHand-*.ttf) from Indie Flower
# (SIL Open Font License): slanted to the right, in two weights, under a name of its own.
# Needs fonttools and skia-pathops. Usage: board-hand.py IndieFlower-Regular.ttf <folder> <bold stroke>
import sys
import pathops
from fontTools.ttLib import TTFont
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen

SLANT = 0.28

def build(source, target, style, weight):
    font = TTFont(source)
    glyphs = font.getGlyphSet()
    drawn = {}
    for name in font.getGlyphOrder():
        path = pathops.Path()
        recording = DecomposingRecordingPen(glyphs)
        glyphs[name].draw(recording)
        recording.replay(TransformPen(path.getPen(), (1, 0, SLANT, 1, weight / 2, 0)))
        if weight:
            outline = pathops.Path(path)
            outline.stroke(weight, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
            outline.convertConicsToQuads()
            path = pathops.op(path, outline, pathops.PathOp.UNION, fix_winding=True)
        pen = TTGlyphPen(None)
        path.draw(Cu2QuPen(pen, 1.0, reverse_direction=True))
        drawn[name] = pen.glyph()
    glyf, hmtx = font["glyf"], font["hmtx"]
    for name, glyph in drawn.items():
        glyf[name] = glyph
        glyph.recalcBounds(glyf)
        hmtx[name] = (hmtx[name][0] + (weight if hmtx[name][0] else 0), getattr(glyph, "xMin", 0))
    bold = style == "Bold"
    names = {1: "Board Hand", 2: style, 3: f"Board Hand {style}", 4: f"Board Hand {style}", 6: f"BoardHand-{style}"}
    table = font["name"]
    table.names = [n for n in table.names if n.nameID in (0, 13, 14)]
    for id, value in names.items():
        table.setName(value, id, 3, 1, 0x409)
        table.setName(value, id, 1, 0, 0)
    font["OS/2"].usWeightClass = 700 if bold else 400
    font["OS/2"].fsSelection = 0x20 if bold else 0x40
    font["head"].macStyle = 1 if bold else 0
    font["post"].italicAngle = 0
    # Its fi and fl ligatures leave a gap after them: letters stay apart.
    for record in font["GSUB"].table.FeatureList.FeatureRecord:
        if record.FeatureTag == "liga": record.Feature.LookupListIndex = []
    for tag in ("DSIG", "FFTM"):
        if tag in font: del font[tag]
    font.save(target)

build(sys.argv[1], sys.argv[2] + "/BoardHand-Regular.ttf", "Regular", 0)
build(sys.argv[1], sys.argv[2] + "/BoardHand-Bold.ttf", "Bold", int(sys.argv[3]))
