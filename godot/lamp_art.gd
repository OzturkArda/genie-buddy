extends Node2D
## The genie's lamp, pixel art in its own SubViewport. The genie lives here while idle.

const W := 56
const H := 30
const SPOUT := Vector2(54, 8)  # where smoke and the genie come out, in lamp pixels

const OUTLINE := Color("3b2504")
const GOLD := Color("e8b531")
const GOLD_LIGHT := Color("fbe39a")
const GOLD_DARK := Color("a8740f")

var glint := 0.0  # 0..1 sweep of a highlight across the body


func _process(delta: float) -> void:
	glint = fmod(glint + delta * 0.25, 1.6)
	queue_redraw()


func _draw() -> void:
	var body := _ellipse(Vector2(26, 19), 14, 7)
	var base := PackedVector2Array([Vector2(20, 24), Vector2(32, 24), Vector2(35, 29), Vector2(17, 29)])
	var spout := PackedVector2Array([Vector2(36, 16), Vector2(46, 11), Vector2(55, 7), Vector2(51, 12), Vector2(40, 22)])
	var lid := _ellipse(Vector2(26, 12), 6, 3)
	for o in [1.0, 0.0]:
		var col: Color = OUTLINE if o else GOLD
		draw_arc(Vector2(11, 18), 5.0, PI * 0.5, PI * 1.5, 12, col, 2.0 + o * 2.0)
		for poly in [base, spout, body, lid]:
			draw_colored_polygon(Geometry2D.offset_polygon(poly, o)[0] if o else poly, col)
		draw_circle(Vector2(26, 8), 2.0 + o, col, true, -1.0, false)
	draw_colored_polygon(_ellipse(Vector2(26, 22), 13, 3), GOLD_DARK)
	draw_colored_polygon(_ellipse(Vector2(21, 16), 5, 2), GOLD_LIGHT)
	draw_line(Vector2(38, 18), Vector2(50, 10), GOLD_DARK)
	draw_rect(Rect2(Vector2(25, 7), Vector2.ONE), GOLD_LIGHT)
	var gx := lerpf(10.0, 44.0, glint)
	if glint < 1.0:
		draw_line(Vector2(gx, 14), Vector2(gx - 3, 23), Color(1, 1, 1, 0.8), 1.0)


func _ellipse(c: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 18:
		var a := TAU * i / 18.0
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts
