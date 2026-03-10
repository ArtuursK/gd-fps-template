extends Node3D

@onready var cube = preload("res://cube_rigidbody.tscn")

func _ready():
	spawn_loop()

func spawn_loop():
	while true:
		drop_cube()
		await get_tree().create_timer(4.0).timeout

func drop_cube():
	var cube = cube.instantiate()
	add_child(cube)

	cube.global_position = Vector3(
		randf_range(-10, 10),
		120,
		randf_range(-10, 10)
	)
	cube.rotation_degrees = Vector3(
		65,
		0,
		45
	)
	 # Get the mesh
	var mesh = cube.get_node("MeshInstance3D")

	# duplicate the existing material
	var mat = mesh.get_surface_override_material(0).duplicate()

	# random colors
	mat.albedo_color = Color(randf_range(0, 1), randf_range(0, 1), randf_range(0, 1))

	# assign back
	mesh.set_surface_override_material(0, mat)
