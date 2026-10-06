extends Node2D
## The genie, drawn with primitives into a low-res SubViewport and scaled up with
## nearest filtering, so it reads as pixel art. Pose and mood blend smoothly.

const W := 96
const H := 128

const OUTLINE := Color("10163f")
const SKIN := Color("3a5fd0")
const SKIN_LIGHT := Color("6d8ef2")
const SKIN_DARK := Color("27409f")
const TAIL := Color("2c48b2")
const TAIL_DARK := Color("1b2b7a")
const TAIL_LIGHT := Color("5d7cec")
const GOLD := Color("e8b531")
const GOLD_DARK := Color("9a6a12")
const EYE := Color("eaf6ff")
const STRIPES := [Color("c0392b"), Color("e8b531"), Color("2e8b57"), Color("2c6fb7"), Color("c0392b")]
const JEWEL := Color("d6202a")

# Elbow / hand offsets from each shoulder (l = genie's right side of the picture's left).
const POSES := {
	"summon":    {"el": Vector2(-11, -13), "hl": Vector2(7, -31), "er": Vector2(11, -13), "hr": Vector2(-7, -31)},
	"point":     {"el": Vector2(-9, 6), "hl": Vector2(-2, 14), "er": Vector2(12, -7), "hr": Vector2(25, -13)},
	"celebrate": {"el": Vector2(-7, -15), "hl": Vector2(-10, -30), "er": Vector2(7, -15), "hr": Vector2(10, -30)},
	"worried":   {"el": Vector2(-13, -2), "hl": Vector2(6, -14), "er": Vector2(13, -2), "hr": Vector2(-6, -14)},
}

var t := 0.0
var target_pose := "summon"
var mood := "neutral"  # neutral | happy | worried | curious | surprised
var pose := {}
var _blink := 0.0
var _next_blink := 2.0


func _ready() -> void:
	pose = POSES.summon.duplicate()


func _process(delta: float) -> void:
	t += delta
	var tgt: Dictionary = POSES[target_pose]
	for k in pose:
		pose[k] = pose[k].lerp(tgt[k], minf(1.0, delta * 7.0))
	_next_blink -= delta
	if _next_blink <= 0.0:
		_blink = 0.14
		_next_blink = randf_range(2.0, 5.5)
	_blink = maxf(0.0, _blink - delta)
	queue_redraw()


func _draw() -> void:
	var b := Vector2(48, 60 + roundf(sin(t * 2.0) * 2.0))
	var sway := Vector2(sin(t * 1.7) * 1.5, cos(t * 1.3))
	if target_pose == "celebrate":
		sway = Vector2(sin(t * 16.0) * 2.0, cos(t * 16.0))
	var sl := b + Vector2(-15, -14)
	var sr := b + Vector2(15, -14)
	var arms := [
		[sl, sl + pose.el + sway * 0.6, sl + pose.hl + sway],
		[sr, sr + pose.er - sway * 0.6, sr + pose.hr - sway],
	]
	var hc := b + Vector2(1, -26) + (Vector2(1, -1) if mood == "curious" else Vector2.ZERO)
	var tail := _tail_points(b)

	# Pass 0 draws every silhouette grown by a pixel in the outline colour; pass 1 fills.
	for pass_i in 2:
		var o := 1.0 if pass_i == 0 else 0.0
		for p in tail:
			_circle(p[0], p[1] + o, OUTLINE if o else TAIL)
		_torso(b, o)
		for a in arms:
			_arm(a[0], a[1], a[2], o)
		_head(hc, o)

	_tail_swirls(tail)
	_torso_detail(b)
	for a in arms:
		_arm_detail(a[0], a[1], a[2])
	_face(hc)
	_turban(hc)


func _tail_points(b: Vector2) -> Array:
	var pts := []
	for i in 20:
		var s := i / 19.0
		var c := Vector2(b.x + sin(s * 5.0 - t * 3.0) * (1.5 + 9.0 * s) * (1.0 - pow(s, 3.0)) + s * s * 10.0, b.y + 8.0 + s * 52.0)
		pts.append([c, lerpf(11.0, 1.5, pow(s, 0.8))])
	return pts


func _tail_swirls(tail: Array) -> void:
	for i in range(0, tail.size() - 2, 2):
		var c: Vector2 = tail[i][0]
		var r: float = tail[i][1]
		var ph := t * 4.0 + i * 0.9
		draw_arc(c, r * 0.7, ph, ph + 2.2, 8, TAIL_LIGHT, 1.0)
		draw_arc(c, r * 0.8, ph + PI, ph + PI + 1.8, 8, TAIL_DARK, 1.0)
	var tip: Vector2 = tail[-1][0]
	for k in 4:
		var p := tip + Vector2(sin(t * 2.3 + k * 1.7) * 5.0, 3.0 - fmod(t * 6.0 + k * 3.0, 12.0))
		draw_rect(Rect2(p.round(), Vector2.ONE), TAIL_LIGHT)


func _torso(b: Vector2, o: float) -> void:
	var torso := PackedVector2Array([b + Vector2(-17, -17), b + Vector2(17, -17), b + Vector2(13, 0),
			b + Vector2(9, 12), b + Vector2(-9, 12), b + Vector2(-13, 0)])
	if o:
		torso = Geometry2D.offset_polygon(torso, o)[0]
	draw_colored_polygon(torso, OUTLINE if o else SKIN)
	_rect(b + Vector2(-4, -22), Vector2(8, 7), o, SKIN_DARK)  # neck
	for s in [b + Vector2(-15, -14), b + Vector2(15, -14)]:
		_circle(s, 5.0 + o, OUTLINE if o else SKIN)


func _torso_detail(b: Vector2) -> void:
	draw_colored_polygon(PackedVector2Array([b + Vector2(9, -17), b + Vector2(17, -17), b + Vector2(13, 0),
			b + Vector2(9, 12), b + Vector2(5, 12), b + Vector2(10, 0)]), SKIN_DARK)
	draw_rect(Rect2(b + Vector2(-11, -14), Vector2(8, 3)), SKIN_LIGHT)
	draw_rect(Rect2(b + Vector2(2, -14), Vector2(6, 2)), SKIN_LIGHT)
	draw_line(b + Vector2(-12, -8), b + Vector2(-2, -6), SKIN_DARK)
	draw_line(b + Vector2(2, -6), b + Vector2(11, -8), SKIN_DARK)
	draw_line(b + Vector2(0, -5), b + Vector2(0, 11), SKIN_DARK)
	for row in 3:
		draw_rect(Rect2(b + Vector2(-5, -3 + row * 4), Vector2(4, 2)), SKIN_LIGHT)
		draw_rect(Rect2(b + Vector2(2, -3 + row * 4), Vector2(3, 2)), SKIN_LIGHT)
	draw_rect(Rect2(b + Vector2(-16, -17), Vector2(3, 2)), SKIN_LIGHT)


func _arm(s: Vector2, e: Vector2, h: Vector2, o: float) -> void:
	var col := OUTLINE if o else SKIN
	draw_line(s, e, col, 7.0 + o * 2.0)
	draw_line(e, h, col, 6.0 + o * 2.0)
	_circle(e, 3.5 + o, col)
	_circle(h, 3.5 + o, col)
	var d := (h - e).normalized()
	var perp := d.orthogonal()
	for k in range(-1, 2):
		var base := h + d * 2.0 + perp * k * 2.0
		var tip := base + d.rotated(k * 0.3) * 5.0
		var curl := tip + d.rotated(k * 0.3 + 1.1) * 2.0
		draw_line(base, tip, col, 1.6 + o * 2.0)
		draw_line(tip, curl, col, 1.2 + o * 2.0)


func _arm_detail(s: Vector2, e: Vector2, h: Vector2) -> void:
	var perp := (e - s).normalized().orthogonal()
	draw_line(s.lerp(e, 0.2) + perp * 1.5, s.lerp(e, 0.7) + perp * 1.5, SKIN_LIGHT, 2.0)
	draw_line(e.lerp(h, 0.6), e.lerp(h, 0.8), GOLD_DARK, 8.0)
	draw_line(e.lerp(h, 0.6), e.lerp(h, 0.78), GOLD, 6.0)


func _head(hc: Vector2, o: float) -> void:
	var col := OUTLINE if o else SKIN
	_circle(hc, 7.0 + o, col)
	var jaw := PackedVector2Array([hc + Vector2(-6, 1), hc + Vector2(6, 1), hc + Vector2(4, 8), hc + Vector2(-4, 8)])
	var ear_l := PackedVector2Array([hc + Vector2(-6, -1), hc + Vector2(-13, -6), hc + Vector2(-6, 3)])
	var ear_r := PackedVector2Array([hc + Vector2(6, -1), hc + Vector2(13, -6), hc + Vector2(6, 3)])
	for poly in [jaw, ear_l, ear_r]:
		draw_colored_polygon(Geometry2D.offset_polygon(poly, o)[0] if o else poly, col)
	if o:
		_turban(hc, o)


func _face(hc: Vector2) -> void:
	draw_rect(Rect2(hc + Vector2(3, -2), Vector2(3, 9)), SKIN_DARK)
	if _blink > 0.0:
		draw_line(hc + Vector2(-4, 0), hc + Vector2(-1, 0), OUTLINE)
		draw_line(hc + Vector2(1, 0), hc + Vector2(4, 0), OUTLINE)
	else:
		draw_rect(Rect2(hc + Vector2(-4, -1), Vector2(3, 2)), EYE)
		draw_rect(Rect2(hc + Vector2(1, -1), Vector2(3, 2)), EYE)
	var brows: Array = {
		"neutral": [Vector2(-5, -3), Vector2(-1, -3), Vector2(1, -3), Vector2(5, -3)],
		"happy": [Vector2(-5, -3), Vector2(-1, -4), Vector2(1, -4), Vector2(5, -3)],
		"worried": [Vector2(-5, -2), Vector2(-1, -4), Vector2(1, -4), Vector2(5, -2)],
		"curious": [Vector2(-5, -3), Vector2(-1, -3), Vector2(1, -5), Vector2(5, -4)],
		"surprised": [Vector2(-5, -4), Vector2(-1, -5), Vector2(1, -5), Vector2(5, -4)],
	}[mood]
	draw_line(hc + brows[0], hc + brows[1], OUTLINE)
	draw_line(hc + brows[2], hc + brows[3], OUTLINE)
	match mood:
		"happy":
			draw_polyline(PackedVector2Array([hc + Vector2(-3, 4), hc + Vector2(-1, 6), hc + Vector2(2, 6), hc + Vector2(4, 4)]), OUTLINE)
		"worried":
			draw_polyline(PackedVector2Array([hc + Vector2(-3, 6), hc + Vector2(0, 5), hc + Vector2(3, 6)]), OUTLINE)
		"surprised":
			draw_rect(Rect2(hc + Vector2(-1, 4), Vector2(3, 3)), OUTLINE)
		_:
			draw_line(hc + Vector2(-2, 5), hc + Vector2(3, 5), OUTLINE)


func _turban(hc: Vector2, o := 0.0) -> void:
	for i in 4:
		_ellipse(hc + Vector2(i % 2, -4 - i * 2.0), 9.8 - i * 1.6 + o, 3.4 - i * 0.2 + o, OUTLINE if o else STRIPES[i])
	if o:
		return
	for i in 3:
		draw_line(hc + Vector2(-7 + i * 3, -2 - i), hc + Vector2(-2 + i * 3, -9 - i), Color(0, 0, 0, 0.18))
	_circle(hc + Vector2(0, -6), 2.6, GOLD)
	_circle(hc + Vector2(0, -6), 1.6, JEWEL)
	draw_rect(Rect2(hc + Vector2(-1, -7), Vector2.ONE), Color.WHITE)


func _circle(c: Vector2, r: float, col: Color) -> void:
	draw_circle(c, r, col, true, -1.0, false)


func _rect(pos: Vector2, size: Vector2, o: float, col: Color) -> void:
	draw_rect(Rect2(pos - Vector2.ONE * o, size + Vector2.ONE * o * 2.0), OUTLINE if o else col)


func _ellipse(c: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16.0
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)
