from lib import *

# 태닝 고양이: sun-tanned caramel tabby skater cat, backwards teal snapback, neon lime hoodie,
# denim shorts, white high-tops, striped tail, purple skateboard with yellow wheels.
PAL = {
    "o": "#6E3C24", "F": "#C27A42", "f": "#8E5428", "C": "#FFE7C9", "P": "#FF8FAB", "E": "#2B1A12",
    "W": "#FFFFFF", "T": "#22C3B5", "t": "#138A85", "L": "#B8F03C", "l": "#7CB51C", "D": "#4D7BD0",
    "V": "#8D52DB", "Y": "#FFC21A", "B": "#7FD3FF", "g": "#98A2B3",
}

HEAD = P("""
....o.......o.....
...oPo.....oPo....
...oPPooooooPPo...
...oPoTTTTTToPfo..
oLLLoTTTTTTTTFfFo.
.oooottttttttfFfo.
..oFFFFFFFFFFFFFo.
..oFfFFFFFFFFFFCCo
.ofFFFFFFFFFFCCPPo
.oFfFFFFFFFCCCCCCo
..oooooooooooooooo
""")
EYES = {  # 7 x 3 at head (7, 6): back eye 2 wide, front eye 3 wide
    "open":  P("EE..EEE\nWY..WYE\nYE..YYE"),
    "blink": P(".......\n.......\nEE..EEE"),
    "happy": P(".......\n.E...E.\nE.E.E.E"),
    "wink":  P("EE..E..\nWY...EE\nYE..E.."),
    "lazy":  P(".......\nEE..EEE\nYE..YYE"),
    "sharp": P(".......\nEE..EEE\nYE..WYE"),
    "sad":   P("E....EE\nWY..WYE\nYE..YYB"),
    "dizzy": P("E...E.E\n.E...E.\nE...E.E"),
}
MOUTH = {  # 3 x 2 at head (14, 9): mouth row + chin row (nose is fixed in HEAD)
    "w":      P("ECE\n..."),
    "smile":  P("EEE\n..."),
    "grin":   P("EWE\nEEo"),
    "open":   P("EEE\nPEo"),
    "chew":   P("CEE\n..."),
    "frown":  P("CEC\n..."),
    "tongue": P("EEE\nPPo"),
}

def head(x, y, eyes="open", mouth="w"):
    return [(HEAD, x, y), (EYES[eyes], x + 7, y + 6), (MOUTH[mouth], x + 14, y + 9)]

TORSO = {  # 13 x 4 at (x + 2, base - 6), drawn under the head (row 0 = hood behind the chin)
    "side": P("""
ooLLLLLLLLLLo
.oLLLLLLLEoLo
.oLLLLLLLLoLo
.olllllllloFo
"""),
    "hold": P("""
ooLLLLLLLLLLo
.oLLLLLLLEoLo
.oLLLLLLLLoFo
.ollllllllooo
"""),
}
SHORTS = P("oDDDDDDDDo")  # at (x + 4, base - 2)
LEGS = {  # 12 x 2 at (x + 3, base - 1): chunky white high-tops, grey soles
    "stand":   P("..oWWo.oWWWo\n..oggo.ogggo"),
    "strideA": P(".oWWo...oWWWo\n.oggo...ogggo"),
    "pass":    P("...oWWooWWWo\n...oggooggggo"),
    "strideB": P("..oWWo.oWWWo\n.oggo...ogggo"),
}
TAILS = [  # striped tail curving up behind the back, 5 x 6 at (x, base - 8)
    P(".oo..\noFfo.\nofo..\noFo..\nofFoo\n.ooFo"),
    P("..oo.\n.oFfo\n.ofo.\noFo..\nofFoo\n.ooFo"),
    P("oo...\noFo..\nofo..\noFo..\nofFoo\n.ooFo"),
    P(".oo..\noFfo.\n.ofo.\n.oFo.\nofFoo\n.ooFo"),
]
CARRY = P("oVVVVVVVVVVVVVVVo\n.Y.............Y.")   # board tucked under the front arm, at (x + 2, base - 3)
CARRY_V = P(".oo.\noVVY\noVVo\noVVo\noVVY\n.oo.")   # board held upright at the side, wheels out
PAW = P("oFo")                                   # front paw resting on the carried deck, at (x + 11, base - 4)
BOARD = P("o..............o\n.oVVVVVVVVVVVVo.\n..oYo......oYo..")   # deck + wheels, 16 x 3

def char(x, base=19, torso="side", legs="stand", eyes="open", mouth="w", tail=0, bob=0):
    L = [(TAILS[tail % 4], x, base - 8)]
    L += [(TORSO[torso], x + 2, base - 6), (SHORTS, x + 4, base - 2)]
    lg = LEGS[legs]
    L.append((lg, x + 3, base - len(lg) + 1))
    L += head(x, base - 16 + bob, eyes, mouth)
    return L

X = 8
poses, extras = {}, {}

def walk(eyes_seq, legs=("strideA", "pass", "strideB", "pass"), dx=0, carry=True, bobs=(0, 1, 0, 1), mouth="w"):
    out = []
    for i, lg in enumerate(legs):
        L = char(X + dx, 19, "hold" if carry else "side", lg, eyes_seq[i], mouth, tail=i, bob=bobs[i])
        if carry: L += [(CARRY_V, X + dx + 13, 13), (PAW, X + dx + 12, 15)]
        out.append(F(L))
    return out

poses["walk"] = walk(["open", "open", "blink", "open"])
poses["slowWalk"] = walk(["lazy", "lazy", "blink", "lazy"], legs=("stand", "pass", "stand", "pass"), bobs=(0, 0, 1, 1), mouth="smile")

# Nap: belly-down on the board, chin on the paws, tail swishing, z drifting up.
LIE = P("""
......oooooooo..
.ooo.oLLLLLLLLo.
oWWWooLLLLLELLo.
ogggoDDlllllllo.
""")
LONG_BOARD = P("o..................o\n.oVVVVVVVVVVVVVVVVo.\n..oYo..........oYo..")
LIE_TAILS = [P("..oo\n.oFo\noFo.\nofo.\noFo."), P(".oo.\noFfo\n.ofo\n.oFo\n.ofo"), P("....\n.oo.\noFfo\n.oFo\n.ofo")]
Z = [P("B"), P("BB\n.B\nBB"), P("BBB\n..B\n.B.\nBBB")]
def nap(i, zs):
    L = [(LIE_TAILS[i % 3], 3, 9), (LIE, 3, 13), (LONG_BOARD, 2, 17)]
    L += head(13, 6, "blink", "w")
    L += [(P("oFFoFFo"), 24, 16)]
    L += [(Z[z], zx, zy) for z, zx, zy in zs]
    return F(L)
poses["lying"] = [nap(0, [(0, 31, 4)]), nap(1, [(1, 31, 2)]), nap(2, [(2, 30, 0), (0, 32, 5)]), nap(1, [(0, 31, 4)])]

# fastWalk: quicker strides, bigger bob, cap brim flicking up on the up-beat.
HEAD_UP = HEAD[:3] + ["oLLoPoTTTTTToPfo..", "...ooTTTTTTTTFfFo."] + HEAD[5:]
def fast(i, lg, eyes, bob, up):
    L = char(X, 19, "hold", lg, eyes, "w", tail=i, bob=bob)
    if up: L[-3] = (HEAD_UP,) + L[-3][1:]
    L += [(CARRY_V, X + 13, 13 + bob), (PAW, X + 12, 15 + bob)]
    return F(L)
poses["fastWalk"] = [fast(0, "strideA", "open", 0, False), fast(1, "pass", "open", 1, True),
                     fast(2, "strideB", "open", 0, False), fast(3, "pass", "blink", 1, True)]

# run: riding the board, kicking with the back foot.
RB = 17                                   # board top row (tips); deck row 18, wheels row 19
FRONT = P("oWWWo\nogggo")                 # front shoe planted on the deck
KICK = [P("......oFFo\n...ooFFo..\n.oWWWo....\n.ogggo...."),   # foot down on the ground behind the board
        P("......oFFo\n..oWWWWo..\n..ogggo...")]                 # foot swinging back up
DUST = [P("g.g"), P(".g.\ng.g")]
def ride(i, mode, eyes="open", mouth="smile", bob=0):
    L = [(TAILS[i % 4], X, RB - 10 + bob), (TORSO["side"], X + 2, RB - 6 + bob), (SHORTS, X + 4, RB - 2)]
    if mode == "ride": L.append((LEGS["stand"], X + 3, RB - 1))
    else: L += [(FRONT, X + 10, RB - 1), (KICK[mode], X - 5, RB - 1)]
    L += head(X, RB - 16 + bob, eyes, mouth)
    L.append((BOARD, X + 1, RB))
    return L
poses["run"] = [F(ride(0, "ride")), F(ride(1, 0, bob=1), (DUST[0], X - 8, 19)),
                F(ride(2, 1, bob=1), (DUST[1], X - 10, 18)), F(ride(3, "ride", "blink"))]

# sprint: crouched low and leaning in, hoodie hem flapping, speed lines streaming behind.
FLAP = [P("oLo\nolo"), P("ooLo\n.olo"), P("oLLo\n.oll")]
LINES = [[(0, 5, 4), (0, 9, 3), (1, 15, 4)], [(1, 5, 3), (0, 9, 4), (0, 15, 3)]]
STREAM = [P("oo.....\nfFoooo.\nofFfFoo\n.oooooo"), P(".......\nooooo..\nFfFfFoo\nooooooo")]  # tail streaming back
CROUCH_LEGS = P("oWWWo.oWWWo\nogggo.ogggo")
def crouch(i, eyes="sharp", mouth="grin"):
    L = [(STREAM[i % 2], X - 4, RB - 7)]
    L += [(TORSO["side"], X + 2, RB - 5), (FLAP[i % 3], X - 1, RB - 5 + (i % 2))]
    L += [(CROUCH_LEGS, X + 3, RB - 1)]
    L += head(X + 2, RB - 14, eyes, mouth)
    L.append((BOARD, X + 1, RB))
    L += [(P("B" * n), x0, y) for x0, y, n in LINES[i % 2]]
    return L
poses["sprint"] = [F(crouch(i, "sharp" if i != 4 else "blink")) for i in range(6)]

# exhausted: slumped sitting on the board, tongue out, dizzy, sweat dripping.
SWEAT = [[(P("B\nB"), 27, 3)], [(P("B"), 28, 5), (P("B\nB"), 7, 6)], [(P("B\nB"), 28, 6), (P("B"), 6, 9)], [(P("B"), 27, 2)]]
def slump(i):
    bob = i % 2
    L = [(TAILS[0], X - 1, RB - 6), (TORSO["side"], X + 2, RB - 4), (SHORTS, X + 4, RB - 1)]
    L += [(FRONT, X + 12, RB - 1), (FRONT, X + 15, RB - 1)]
    L += head(X, RB - 13 + bob, "dizzy", "tongue" if bob == 0 else "open")
    L.append((BOARD, X + 1, RB + 0))
    L += SWEAT[i]
    return F(L)
poses["exhausted"] = [slump(i) for i in range(4)]

def over(base, top):
    """Paint the non-transparent pixels of frame `top` over frame `base`."""
    return ["".join(t if t != "." else b for b, t in zip(br, tr)) for br, tr in zip(base, top)]

# hungry: holding out an empty bowl, sad, looking back and forth, a "?" popping up.
BOWL = P("oooooooo\noBBBBBBo\n.oBBBBo.\n..oooo..")
QM = [P("TT.\n..T\n.T.\n...\n.T."), P(".TT.\nT..T\n..T.\n.T..\n....\n.T..")]
def hungry(i):
    look_back = i in (1, 3)
    L = char(X, 19, "hold", "stand", "sad", "frown", tail=i)
    hd = L[-3:]
    L = L[:-3] + [(BOWL, X + 15, 13 + (i == 2)), (PAW, X + 13, 15)]
    fr = F(L)
    h = F(hd)
    if look_back: h = flip_cols(h, X, X + 18)
    fr = over(fr, h)
    return stamp_all(fr, [(QM[i % 2], 28 if not look_back else 2, 1 + (i % 2 == 0))])
extras["hungry"] = [hungry(i) for i in range(4)]

# eat: fish snack to the mouth, bites, cheeks bulging, then a satisfied smile and a heart.
FISH = P(".oooo.o\noEYYYoY\noYYYYYo\n.oooo.o")
FISHES = [FISH, [r[2:] for r in FISH], [r[4:] for r in FISH], None]
CHEEK = P("o\no")
HEART = P("P.P\nPPP\n.P.")
def eat(i):
    L = char(X, 19, "side", "stand", ["open", "happy", "happy", "happy"][i], ["open", "chew", "chew", "smile"][i], tail=i)
    if FISHES[i]: L += [(FISHES[i], X + 16 + 2 * min(i, 2), 11), (P("oFFo\n.oo."), X + 18, 14), (P("oo\nFo"), X + 16, 15)]
    if i in (1, 2): L += [(CHEEK, X + 18, 10)]
    if i == 2: L += [(P("Y"), X + 22, 16), (P("Y"), X + 20, 18)]
    if i == 3: L += [(HEART, 28, 1), (P("P"), 26, 5)]
    return F(L)
extras["eat"] = [eat(i) for i in range(4)]

# special 킥플립: crouch, pop, the board spins under the feet (edge-on, upside down, upright), land, wink.
EDGE = P(".oooooooooooooo.\noVVVVVVVVVVVVVVo\noYVVVVVVVVVVVVYo\n.oooooooooooooo.")
UPSIDE = BOARD[::-1]
STAR = P(".Y.\nYWY\n.Y.")
def kick(dy, eyes, mouth, board, by, tail=0):
    L = [(TAILS[tail % 4], X - 1, RB - 7 + dy), (TORSO["side"], X + 2, RB - 5 + dy), (CROUCH_LEGS, X + 3, RB - 1 + dy)]
    L += head(X + 1, RB - 14 + dy, eyes, mouth)
    L.append((board, X + 1, by))
    return L
def spec(i):
    if i == 0: L = kick(0, "sharp", "smile", BOARD, RB)
    elif i == 1: L = kick(-3, "sharp", "grin", BOARD, RB - 3, 1) + [(DUST[1], X - 1, 18), (DUST[1], X + 15, 18)]
    elif i == 2: L = kick(-3, "open", "grin", EDGE, RB - 1, 2)
    elif i == 3: L = kick(-3, "open", "grin", UPSIDE, RB - 1, 3)
    elif i == 4: L = kick(-2, "sharp", "grin", BOARD, RB - 2, 0)
    elif i == 5: L = kick(0, "happy", "grin", BOARD, RB, 1) + [(DUST[0], X - 3, 19), (DUST[0], X + 17, 19)]
    else:
        L = ride(i, "ride", "wink", "grin" if i == 6 else "smile")
        sp = [(27, 1), (3, 4), (30, 9)] if i == 6 else [(29, 3), (4, 1), (2, 10)]
        L += [(STAR, a, b) for a, b in sp]
    return F(L)
extras["special"] = [spec(i) for i in range(8)]
PEEK = poses["walk"][:2] + poses["lying"][:1]

data = {"palette": PAL, "poses": {k: poses[k] for k in POSES}, "extras": {k: extras[k] for k in EXTRAS}}
HOP_OK = {("special", 1), ("special", 2), ("special", 3), ("special", 4)}
