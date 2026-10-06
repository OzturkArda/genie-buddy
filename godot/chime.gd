## Synthesised sounds, so the prototype ships no audio assets.

const RATE := 22050


static func make(notes: Array, step: float, vol: float) -> AudioStreamWAV:
	var total := int(RATE * (step * notes.size() + 0.8))
	var data := PackedByteArray()
	data.resize(total * 2)
	for i in total:
		var tt := float(i) / RATE
		var v := 0.0
		for n in notes.size():
			var lt := tt - n * step
			if lt >= 0.0:
				var f: float = notes[n]
				v += sin(TAU * f * lt) * exp(-lt * 5.0) + 0.35 * sin(TAU * f * 2.0 * lt) * exp(-lt * 9.0)
		data.encode_s16(i * 2, int(clampf(v * vol, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


static func sparkle() -> AudioStreamWAV:
	return make([880.0, 1108.7, 1318.5, 1760.0], 0.09, 0.28)


static func alarm() -> AudioStreamWAV:
	return make([659.3, 493.9, 659.3, 493.9], 0.16, 0.32)


static func soft() -> AudioStreamWAV:
	return make([659.3, 987.8], 0.12, 0.2)
