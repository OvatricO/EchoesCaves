extends RefCounted
# Shared horror-game UI helpers: styles, glowing panels, hover/click sounds, shake.

const RED := Color(0.85, 0.12, 0.14)
const GOLD := Color(1.0, 0.8, 0.3)
const DARK := Color(0.05, 0.04, 0.06, 0.96)

static var _snd_hover: AudioStreamWAV
static var _snd_click: AudioStreamWAV


static func _tone(freq: float, dur: float, vol: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		var env := 1.0 - float(i) / float(n)
		var s := sin(TAU * freq * float(i) / float(rate)) * env * env * vol
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w


static func panel_style(border: Color = RED, glow: float = 18.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = DARK
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(2)
	sb.border_color = border
	sb.shadow_color = Color(border.r, border.g, border.b, 0.45)
	sb.shadow_size = int(glow)
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	return sb


static func attach_sfx(b: BaseButton) -> void:
	if _snd_hover == null:
		_snd_hover = _tone(1400.0, 0.05, 0.12)
		_snd_click = _tone(300.0, 0.12, 0.35)
	var p := AudioStreamPlayer.new()
	b.add_child(p)
	b.mouse_entered.connect(func():
		if not b.disabled:
			p.stream = _snd_hover
			p.play())
	b.pressed.connect(func():
		p.stream = _snd_click
		p.play())


static func fade_in(c: Control, secs: float = 0.35) -> void:
	c.modulate.a = 0.0
	c.create_tween().tween_property(c, "modulate:a", 1.0, secs)


# shake a node that is NOT inside a container (moves position.x)
static func shake(c: Control) -> void:
	var x := c.position.x
	var t := c.create_tween()
	for d in [-14.0, 14.0, -10.0, 10.0, -5.0, 5.0, 0.0]:
		t.tween_property(c, "position:x", x + d, 0.045)


class Spinner extends Control:
	var _a := 0.0

	func _process(delta: float) -> void:
		_a += delta * 6.0
		queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		draw_arc(c, size.x * 0.4, _a, _a + PI * 1.3, 24, Color(1.0, 0.8, 0.3), 4.0, true)
		draw_arc(c, size.x * 0.4, _a + PI, _a + PI * 1.0 + 0.4, 6, Color(0.85, 0.12, 0.14), 4.0, true)
