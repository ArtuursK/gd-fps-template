extends RigidBody3D

const CAMERA_CONTROLLER_ROTATION_SPEED := 3.0
const CAMERA_MOUSE_ROTATION_SPEED := 0.003
# A minimum angle lower than or equal to -90 breaks movement if the player is looking upward.
const CAMERA_X_ROT_MIN := deg_to_rad(-89.9)
const CAMERA_X_ROT_MAX := deg_to_rad(70)

const FOV_DEFAULT := 75.0
const FOV_AIM := 65.0      # smaller = more zoom
const AIM_ZOOM_TIME := 0.12     # seconds

# Camera and effects
@export var camera_animation : AnimationPlayer
@export var camera_base : Node3D
@export var camera_rot : Node3D
@onready var camera_camera: Camera3D = $Target/Camera3D
@export var color_rect : ColorRect
@export var body_visual: Node3D
@export var aiming := false

@onready var shape_cast = $ShapeCast3D
@onready var start_position = position

var _was_on_ground := false

# grabbing and shooting
@export var hold_distance := 3.0
@export var max_pick_distance := 8.0
@export var only_grabbable_group := true
@export var grabbable_group_name := "grabbable"

@export var hold_point: Marker3D


var held_body: RigidBody3D = null
var _pin_joint: PinJoint3D = null
var _grab_anchor: StaticBody3D = null
var _grab_offset_local := Vector3.ZERO
var _original_gravity_scale := 1.0 # Store original gravity scale
# Removed _original_collision_mask - collisions will now stay active!

func _ready():
	camera_camera.make_current()
	camera_camera.fov = FOV_DEFAULT
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# Ensure a HoldPoint exists and follows the camera look
	if hold_point == null:
		hold_point = Marker3D.new()
		hold_point.name = "HoldPoint"
		camera_rot.add_child(hold_point) # parent to the thing that rotates with view
		hold_point.transform = Transform3D.IDENTITY

func _physics_process(_delta):
	var camera_move = Vector2(
			Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
			Input.get_action_strength("ui_up") - Input.get_action_strength("ui_down"))
			
	var camera_speed_this_frame = _delta * CAMERA_CONTROLLER_ROTATION_SPEED
	rotate_camera(camera_move * camera_speed_this_frame)
	
	var grounded: bool = on_ground()
	_was_on_ground = grounded
				
	# Handle grab / release input (TOGGLE WITH "grab")
	if Input.is_action_just_pressed("grab"):
		if held_body:
			_release() # Release on press if holding
		else:
			_try_grab() # Try to grab on press if not holding
	
	# The "shoot" action (implied mouse click) now performs a strong toss
	elif Input.is_action_just_pressed("shoot") and held_body:
		_release(true) # Pass true to apply a throwing force

	# While holding, keep the anchor in front of the camera
	_update_hold_anchor()

	if Input.is_action_just_pressed(&"exit"):
		get_tree().quit()
		
	if Input.is_action_just_pressed(&"reset_position") or global_position.y < -40:
		# Pressed the reset key or fell off the ground.
		position = start_position
		linear_velocity = Vector3.ZERO

	# Read raw input
	var input_dir := Vector2(
		Input.get_axis(&"move_left", &"move_right"),
		Input.get_axis(&"move_back",  &"move_forward")
	)

	# Build a camera-yaw-based direction (ignore pitch)
	var basis := camera_base.global_transform.basis
	var forward := -basis.z
	var right   :=  basis.x
	var wishdir := (right * input_dir.x + forward * input_dir.y)
	wishdir.y = 0.0
	if wishdir.length() > 0.0:
		wishdir = wishdir.normalized()

	# Air movement
	apply_central_impulse(wishdir * 0.04)

	if on_ground():
		apply_central_impulse(wishdir * 0.08)
		if Input.is_action_pressed(&"jump"):
			linear_velocity.y = 7.0

	# make the player face the cameras view
	# (Best: rotate a visual child, not the rigid body itself.)
	if is_instance_valid(body_visual):
		body_visual.rotation.y = camera_base.rotation.y

# Feed mouse movement into the same rotate helper.
func _input(event):
	# Make mouse aiming speed resolution-independent
	# (required when using the `canvas_items` stretch mode).
	var scale_factor: float = min(
			(float(get_viewport().size.x) / get_viewport().get_visible_rect().size.x),
			(float(get_viewport().size.y) / get_viewport().get_visible_rect().size.y)
	)
	
	if event is InputEventMouseMotion:
		var camera_speed_this_frame = CAMERA_MOUSE_ROTATION_SPEED
		if aiming:
			camera_speed_this_frame *= 0.75
		rotate_camera(-event.relative * camera_speed_this_frame * scale_factor)
		

func rotate_camera(move: Vector2) -> void:
	camera_base.rotate_y(move.x)
	# After relative transforms, camera needs to be renormalized.
	camera_base.orthonormalize()
	camera_rot.rotation.x = clamp(camera_rot.rotation.x + move.y, CAMERA_X_ROT_MIN, CAMERA_X_ROT_MAX)

# Test if there is a body below the player.
func on_ground() -> bool:
	return shape_cast.is_colliding()


func _on_tcube_body_entered(body):
	if body == self:
		get_node(^"WinText").show()
		
		
func _camera_ray(max_dist: float) -> Dictionary:
	var vp := get_viewport()
	var screen_pos: Vector2 = vp.get_visible_rect().size * 0.5
	var origin: Vector3 = camera_camera.project_ray_origin(screen_pos)
	var dir: Vector3 = camera_camera.project_ray_normal(screen_pos)
	var to: Vector3 = origin + dir * max_dist

	var query := PhysicsRayQueryParameters3D.create(origin, to)
	query.exclude = [self]          # don't hit the player
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_ray(query)
	
	
	
func _try_grab():
	if held_body: 
		return
	var hit := _camera_ray(max_pick_distance)
	if hit.is_empty():
		return

	var body = hit.get("collider")
	if body == null or not (body is RigidBody3D):
		return
	#if only_grabbable_group and not body.is_in_group(grabbable_group_name):
		#return

	held_body = body
	
	# === GRAB SETUP: Center and Lock Object to View ===
	# 1a. Store original gravity and set it to 0 so the object floats.
	_original_gravity_scale = held_body.gravity_scale
	held_body.gravity_scale = 0.0
	
	# 1c. Stop all current movement on the held body immediately.
	held_body.linear_velocity = Vector3.ZERO
	held_body.angular_velocity = Vector3.ZERO
	# --- Stop any unwanted rotation
	held_body.angular_damp += 10.0 # Greatly increase angular dampening
	# ===============================================

	# Calculate the target global position (centered and 'hold_distance' away)
	var cam_xform = camera_camera.global_transform
	var target_global_pos = cam_xform.origin + (-cam_xform.basis.z) * hold_distance
	
	# --- NEW: Immediately snap the held body to the target position and rotation ---
	var target_transform = Transform3D(cam_xform.basis, target_global_pos)
	held_body.global_transform = target_transform
	# -----------------------------------------------------------------------------
	
	# Place hold_point at the target position.
	hold_point.global_transform.origin = target_global_pos

	# Create (or reuse) an invisible static anchor and a pin joint.
	if _grab_anchor == null:
		_grab_anchor = StaticBody3D.new()
		_grab_anchor.name = "GrabAnchor"
		add_child(_grab_anchor)

	# Keep the anchor at the hold_point (This also sets rotation from the camera).
	_grab_anchor.global_transform = hold_point.global_transform

	# --- Pivot at the object's local center (Vector3.ZERO) ---
	_grab_offset_local = Vector3.ZERO 

	# Create the joint
	_pin_joint = PinJoint3D.new()
	_pin_joint.node_a = _grab_anchor.get_path()
	_pin_joint.node_b = held_body.get_path()

	add_child(_pin_joint)                       # <-- add to tree first
	# Pivot is set where both bodies currently are: target_global_pos
	_pin_joint.global_position = target_global_pos

	# === Joint Stiffness Tweak ===
	# Increased stiffness parameters to try and overcome collision/gravity drag
	if _pin_joint.has_method("set_param"):
		_pin_joint.set_param(PinJoint3D.PARAM_BIAS, 0.8) # Stronger correction factor
		_pin_joint.set_param(PinJoint3D.PARAM_DAMPING, 1.5) # Slight increase in damping

	# Optional: increase linear damping while held for less jitter
	held_body.linear_damp += 4.0
	
func _release(toss: bool = false):
	if not held_body:
		return

	held_body.gravity_scale = _original_gravity_scale
	
	# Apply player's velocity to the released object for a smoother toss/drop
	# This uses the current linear_velocity of the player RigidBody3D (self)
	held_body.linear_velocity = linear_velocity 
	
	if toss:
		var throw_direction = -camera_camera.global_transform.basis.z
		held_body.apply_central_impulse(throw_direction * 20.0)

	# Restore damping (reverse what we added)
	held_body.linear_damp = max(0.0, held_body.linear_damp - 4.0)
	held_body.angular_damp = max(0.0, held_body.angular_damp - 10.0) # Restore stronger angular damp
	held_body.angular_damp = max(0.0, held_body.angular_damp) # Clamp to ensure it doesn't go negative

	if is_instance_valid(_pin_joint):
		_pin_joint.queue_free()
	_pin_joint = null
	held_body = null
	
	
func _update_hold_anchor():
	if not held_body or _grab_anchor == null:
		return
		
	# 1. Update the position of the anchor in front of the camera
	var cam = camera_camera.global_transform
	var target_pos = cam.origin + (-cam.basis.z) * hold_distance
	
	# Ensure the anchor inherits the camera's position and rotation
	hold_point.global_transform.origin = target_pos
	
	# The grab anchor inherits the hold_point's transform
	_grab_anchor.global_transform = hold_point.global_transform
	
	# --- Update the joint's global pivot position for continuous tracking ---
	if is_instance_valid(_pin_joint):
		_pin_joint.global_position = target_pos
	
	# 2. Force the held body's rotation to match the anchor's rotation
	# This is what locks the object's view to the camera's orientation.
	held_body.global_transform.basis = _grab_anchor.global_transform.basis
	held_body.angular_velocity = Vector3.ZERO
	
