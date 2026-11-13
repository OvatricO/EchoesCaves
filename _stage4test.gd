extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30, 0.2, 30)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.1, 0)
	root.add_child(floor_body)
	for kind in ["wolf", "duck"]:
		var c = load("res://creature.gd").new()
		root.add_child(c)
		var wps: Array[Vector3] = [Vector3(2, 0, 0), Vector3(-2, 0, 0)]
		c.setup(kind, kind + "-base", 1.0, 0.01, 0.01, 0.0, 0.0, wps)
		c.place(Vector3.ZERO)
		c.active = true
		for i in range(10):
			await process_frame
		print(kind, " settle root_y=", snappedf(c.global_position.y, 0.001), " head=", c._eyes.global_position)
		c._lunge()
		for i in range(6):
			await process_frame
		print(kind, " mid lunge_t=", snappedf(c._lunge_t, 0.001), " z=", snappedf(c._model.position.z, 0.001),
			" tilt=", snappedf(c._model.rotation.x, 0.001), " eye_y=", snappedf(c._eyes.global_position.y, 0.001))
		await create_timer(0.8).timeout
		print(kind, " end lunge_t=", snappedf(c._lunge_t, 0.001), " z=", snappedf(c._model.position.z, 0.001),
			" tilt=", snappedf(c._model.rotation.x, 0.001))
		c.queue_free()
		await process_frame
	print("STAGE4TEST done")
	quit()
