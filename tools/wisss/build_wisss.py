"""Builds Wisss, the presenter, from primitives: body, skeleton, face shape keys, props.

Measurements are in pixels of the front view in wisss.png (x from the centre line,
d depth with negative = front, y image row), converted to metres by PX.

  blender -b --factory-startup --python tools/wisss/build_wisss.py -- --out models/wisss
  add --preview DIR to also render the turnaround and the talk pose with Cycles.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector, noise
from mathutils.bvhtree import BVHTree

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def arg(name, default=None):
	for a in argv:
		if a.startswith("--%s=" % name):
			return a.split("=", 1)[1]
	return default


HEIGHT = 1.6
PX = HEIGHT / 420.0


def P(x, d, y):
	return Vector((x * PX, d * PX, (480.0 - y) * PX))


def D(x, d, z_up):
	"""Direction or offset in pixels, z pointing up."""
	return Vector((x, d, z_up)) * PX


# --- materials ----------------------------------------------------------------

COLORS = {
	"skin": (226, 196, 176),
	"hair": (200, 156, 90),
	"jacket": (50, 58, 102),
	"shirt": (236, 236, 230),
	"tie": (150, 34, 38),
	"trousers": (62, 64, 70),
	"shoes": (30, 30, 32),
	"eyes": (18, 18, 16),
	"mouth": (45, 30, 28),
	"cash": (122, 170, 98),
	"cash_print": (90, 140, 78),
	"mic": (28, 28, 30),
	"grill": (150, 150, 155),
}
MAT_ORDER = list(COLORS)


def srgb_to_linear(c):
	c /= 255.0
	return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def make_material(name, rgb, roughness=0.62):
	mat = bpy.data.materials.new("wisss_" + name)
	mat.use_nodes = True
	nodes = mat.node_tree.nodes
	links = mat.node_tree.links
	bsdf = nodes["Principled BSDF"]
	bsdf.inputs["Base Color"].default_value = (*[srgb_to_linear(c) for c in rgb], 1.0)
	bsdf.inputs["Roughness"].default_value = roughness
	# Fingerprint-scale unevenness so it reads as clay in Blender renders.
	tex = nodes.new("ShaderNodeTexNoise")
	tex.inputs["Scale"].default_value = 140.0
	tex.inputs["Detail"].default_value = 4.0
	bump = nodes.new("ShaderNodeBump")
	bump.inputs["Strength"].default_value = 0.12
	links.new(tex.outputs["Fac"], bump.inputs["Height"])
	links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
	return mat


MATERIALS = {}

# --- mesh helpers ---------------------------------------------------------------


def with_modifiers(bm, mods):
	me = bpy.data.meshes.new("tmp")
	bm.to_mesh(me)
	bm.free()
	ob = bpy.data.objects.new("tmp", me)
	bpy.context.scene.collection.objects.link(ob)
	for kind, props in mods:
		m = ob.modifiers.new(kind, kind)
		for k, v in props.items():
			setattr(m, k, v)
	dg = bpy.context.evaluated_depsgraph_get()
	out = bmesh.new()
	out.from_object(ob, dg)
	bpy.data.objects.remove(ob)
	bpy.data.meshes.remove(me)
	return out


def ellipsoid(center, radii_px, rot=None, segs=32, rings=16):
	bm = bmesh.new()
	bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=1.0)
	r = rot.to_4x4() if rot is not None else Matrix()
	m = Matrix.Translation(center) @ r @ Matrix.Diagonal((*(Vector(radii_px) * PX), 1.0))
	bmesh.ops.transform(bm, matrix=m, verts=bm.verts)
	return bm


def rounded_box(center, size_px, bevel_px, taper_top=1.0, levels=1):
	bm = bmesh.new()
	bmesh.ops.create_cube(bm, size=1.0)
	for v in bm.verts:
		sx = size_px[0] * (taper_top if v.co.z > 0 else 1.0)
		v.co = Vector((v.co.x * sx, v.co.y * size_px[1], v.co.z * size_px[2])) * PX + center
	return with_modifiers(bm, [
		("BEVEL", dict(width=bevel_px * PX, segments=4, limit_method="NONE")),
		("SUBSURF", dict(levels=levels)),
	])


def tube(points, radii_px, segs=20, step_px=5.0, ref=Vector((0.0, -1.0, 0.0))):
	"""Closed tube through points; radii_px[i] = (across, other) at points[i]."""
	lengths = [0.0]
	for a, b in zip(points, points[1:]):
		lengths.append(lengths[-1] + (b - a).length)
	total = lengths[-1]
	n = max(2, int(total / (step_px * PX)) + 1)
	bm = bmesh.new()
	rings = []
	u_prev = None
	for i in range(n):
		s = total * i / (n - 1)
		j = min(len(points) - 2, max(k for k in range(len(points) - 1) if lengths[k] <= s + 1e-9))
		f = (s - lengths[j]) / max(lengths[j + 1] - lengths[j], 1e-9)
		c = points[j].lerp(points[j + 1], f)
		ra = Vector(radii_px[j]).lerp(Vector(radii_px[j + 1]), f) * PX
		t = (points[j + 1] - points[j]).normalized()
		if u_prev is None:
			u = ref - t * t.dot(ref)
			if u.length < 1e-6:
				u = Vector((1.0, 0.0, 0.0)) - t * t.x
		else:
			u = u_prev - t * t.dot(u_prev)
		u.normalize()
		u_prev = u
		v = t.cross(u)
		ring = []
		for k in range(segs):
			a = 2.0 * math.pi * k / segs
			ring.append(bm.verts.new(c + u * math.cos(a) * ra.x + v * math.sin(a) * ra.y))
		rings.append((ring, c, t, min(ra)))
	for (r0, *_), (r1, *_) in zip(rings, rings[1:]):
		for k in range(segs):
			bm.faces.new((r0[k], r0[(k + 1) % segs], r1[(k + 1) % segs], r1[k]))
	ring, c, t, r = rings[0]
	tip = bm.verts.new(c - t * r * 0.6)
	for k in range(segs):
		bm.faces.new((tip, ring[(k + 1) % segs], ring[k]))
	ring, c, t, r = rings[-1]
	tip = bm.verts.new(c + t * r * 0.6)
	for k in range(segs):
		bm.faces.new((tip, ring[k], ring[(k + 1) % segs]))
	return bm


def frame(y_dir, z_hint):
	y = y_dir.normalized()
	x = y.cross(z_hint).normalized()
	z = x.cross(y)
	return Matrix((x, y, z)).transposed()


class Surfaces:
	"""Front-facing depth lookups (ray cast along +Y) against already built parts."""

	def __init__(self):
		self.trees = []

	def add(self, bm):
		bm.faces.ensure_lookup_table()
		self.trees.append(BVHTree.FromBMesh(bm))

	def depth(self, x_px, y_img, fallback_px):
		o = P(x_px, -300, y_img)
		best = None
		for tree in self.trees:
			hit = tree.ray_cast(o, Vector((0.0, 1.0, 0.0)))
			if hit[0] is not None and (best is None or hit[0].y < best):
				best = hit[0].y
		return best / PX if best is not None else fallback_px


def decal(fn, rows, cols, surf, lift_px, thick_px, fallback_px=-40.0):
	"""A thin plate laid on the front of surf; fn(u, v) -> (x_px, y_img)."""
	bm = bmesh.new()
	grid = []
	for i in range(rows + 1):
		row = []
		for j in range(cols + 1):
			x, y = fn(j / cols, i / rows)
			d = surf.depth(x, y, fallback_px) - lift_px
			row.append(bm.verts.new(P(x, d, y)))
		grid.append(row)
	for i in range(rows):
		for j in range(cols):
			f = bm.faces.new((grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]))
	bm.normal_update()
	if sum(f.normal.y for f in bm.faces) > 0:
		bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
	return with_modifiers(bm, [
		("SOLIDIFY", dict(thickness=thick_px * PX, offset=-1.0)),
		("SUBSURF", dict(levels=1)),
	])


# --- skeleton (rest A-pose) --------------------------------------------------------

ARM_ANGLE = math.radians(30.0)
UPPER_ARM, LOWER_ARM, HAND = 62.0, 55.0, 26.0


def arm_joints(side):
	s = P(50 * side, 6, 238)
	down = D(math.sin(ARM_ANGLE) * side, 0, -math.cos(ARM_ANGLE)).normalized()
	e = s + down * UPPER_ARM * PX
	w = e + down * LOWER_ARM * PX
	return s, e, w, w + down * HAND * PX, down


BONES = {}  # name -> (head, tail, parent, connected)


def define_bones():
	BONES["Hips"] = (P(0, 6, 330), P(0, 6, 300), None, False)
	BONES["Spine"] = (P(0, 6, 300), P(0, 6, 262), "Hips", True)
	BONES["Chest"] = (P(0, 6, 262), P(0, 6, 222), "Spine", True)
	BONES["Neck"] = (P(0, 6, 222), P(0, 4, 198), "Chest", True)
	BONES["Head"] = (P(0, 4, 198), P(0, 4, 70), "Neck", True)
	for side, name in ((1, "Left"), (-1, "Right")):
		s, e, w, h, _ = arm_joints(side)
		BONES[name + "Shoulder"] = (P(6 * side, 6, 226), s, "Chest", False)
		BONES[name + "UpperArm"] = (s, e, name + "Shoulder", True)
		BONES[name + "LowerArm"] = (e, w, name + "UpperArm", True)
		BONES[name + "Hand"] = (w, h, name + "LowerArm", True)
		BONES[name + "UpperLeg"] = (P(27 * side, 4, 332), P(27 * side, 4, 396), "Hips", False)
		BONES[name + "LowerLeg"] = (P(27 * side, 4, 396), P(27 * side, 6, 452), name + "UpperLeg", True)
		BONES[name + "Foot"] = (P(27 * side, 6, 452), P(27 * side, -14, 472), name + "LowerLeg", True)
		BONES[name + "Toes"] = (P(27 * side, -14, 472), P(27 * side, -34, 474), name + "Foot", True)


def build_armature():
	arm_data = bpy.data.armatures.new("WisssRig")
	arm = bpy.data.objects.new("Wisss", arm_data)
	bpy.context.scene.collection.objects.link(arm)
	bpy.context.view_layer.objects.active = arm
	bpy.ops.object.mode_set(mode="EDIT")
	for name, (head, tail, parent, connected) in BONES.items():
		eb = arm_data.edit_bones.new(name)
		eb.head, eb.tail = head, tail
		# Local Z points forward (thumb side for the hands).
		eb.align_roll(Vector((0.0, -1.0, 0.0)) if abs((tail - head).normalized().y) < 0.9 else Vector((0.0, 0.0, 1.0)))
	for name, (_, _, parent, connected) in BONES.items():
		if parent:
			eb = arm_data.edit_bones[name]
			eb.parent = arm_data.edit_bones[parent]
			eb.use_connect = connected
	bpy.ops.object.mode_set(mode="OBJECT")
	return arm


def seg_dist(p, a, b):
	ab = b - a
	t = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
	return (a + ab * t - p).length


def bone_weights(p, bones, power):
	ws = []
	for name in bones:
		head, tail = BONES[name][0], BONES[name][1]
		ws.append(1.0 / (seg_dist(p, head, tail) + 0.002) ** power)
	total = sum(ws)
	out = {n: w / total for n, w in zip(bones, ws) if w / total > 0.01}
	total = sum(out.values())
	return {n: w / total for n, w in out.items()}


# --- body -------------------------------------------------------------------------


class Assembly:
	def __init__(self):
		self.bm = bmesh.new()
		self.rules = []  # (first_vert, last_vert, bones, power)

	def add(self, part, mat, bones, power=6.0):
		me = bpy.data.meshes.new("tmp")
		part.to_mesh(me)
		part.free()
		v0, f0 = len(self.bm.verts), len(self.bm.faces)
		self.bm.from_mesh(me)
		bpy.data.meshes.remove(me)
		self.bm.faces.ensure_lookup_table()
		for i in range(f0, len(self.bm.faces)):
			self.bm.faces[i].material_index = MAT_ORDER.index(mat)
		self.rules.append((v0, len(self.bm.verts), bones, power))

	def finish(self, name, arm):
		me = bpy.data.meshes.new(name)
		self.bm.to_mesh(me)
		self.bm.free()
		for mat in MAT_ORDER:
			me.materials.append(MATERIALS[mat])
		for poly in me.polygons:
			poly.use_smooth = True
		ob = bpy.data.objects.new(name, me)
		bpy.context.scene.collection.objects.link(ob)
		groups = {n: ob.vertex_groups.new(name=n) for n in BONES}
		for v0, v1, bones, power in self.rules:
			for i in range(v0, v1):
				for n, w in bone_weights(me.vertices[i].co, bones, power).items():
					groups[n].add([i], w, "REPLACE")
		ob.parent = arm
		ob.modifiers.new("Armature", "ARMATURE").object = arm
		return ob


HEAD_C, HEAD_R = (0.0, 2.0, 150.0), (61.0, 64.0, 58.0)


def head_surface(x, y_img, inset_px):
	"""Point on the front of the head ellipsoid and its outward normal."""
	cx, cd, cy = HEAD_C
	rx, rd, rz = HEAD_R
	zu = cy - y_img
	d = cd - rd * math.sqrt(max(0.0, 1.0 - (x / rx) ** 2 - (zu / rz) ** 2))
	n = Vector((x / rx ** 2, (d - cd) / rd ** 2, zu / rz ** 2)).normalized()
	return P(x, d, y_img) - n * inset_px * PX, n


def build_hair():
	hc = P(0, 12, 140)
	rx, rd, rz = 73.0, 78.0, 82.0
	bm = ellipsoid(hc, (rx, rd, rz), segs=64, rings=32)

	def boundary(phi):
		# Image row of the hair's lower edge: fringe at the front, nape at the back.
		b = 120.0 + 75.0 * ((1.0 - math.cos(phi)) / 2.0) ** 1.32
		return b + 3.0 * math.sin(5.0 * phi + 0.6) * max(0.0, math.cos(phi))

	cut = []
	for v in bm.verts:
		rel = v.co - hc
		phi = math.atan2(rel.x, -rel.y)
		y_img = 480.0 - v.co.z / PX
		if y_img > boundary(phi):
			cut.append(v)
	bmesh.ops.delete(bm, geom=cut, context="VERTS")
	bm = with_modifiers(bm, [
		("SOLIDIFY", dict(thickness=6.0 * PX, offset=-1.0)),
		("SUBSURF", dict(levels=1)),
	])
	# Locks: ridges running down from the crown.
	for v in bm.verts:
		rel = v.co - hc
		phi = math.atan2(rel.x, -rel.y)
		elev = rel.z / (rz * PX)
		g = math.sin(11.0 * phi + 3.0 * noise.noise(rel * 7.0))
		lump = noise.noise(rel * 4.0 + Vector((3.1, 1.7, 0.4)))
		fade = 0.35 + 0.65 * max(0.0, min(1.0, (0.95 - elev) / 0.5))
		v.co += rel.normalized() * ((2.5 * g + 4.0 * lump) * fade) * PX
	parts = [bm]
	# Chunky fringe clumps, swept towards image left.
	for deg in (-62, -38, -14, 10, 34, 58):
		phi = math.radians(deg)
		y_img = boundary(phi) - 10.0
		zu = 140.0 - y_img
		k = math.sqrt(max(0.0, 1.0 - (zu / rz) ** 2))
		c = hc + D(math.sin(phi) * rx * k * 0.97, -math.cos(phi) * rd * k * 0.97, zu)
		rot = Matrix.Rotation(-phi, 3, "Z") @ Matrix.Rotation(math.radians(-14.0), 3, "Y") @ Matrix.Rotation(math.radians(-18.0), 3, "X")
		parts.append(ellipsoid(c, (11.0, 7.0, 16.0), rot, segs=20, rings=12))
	return parts


def build_body(arm):
	asm = Assembly()
	surf = Surfaces()
	head_bones, chest_bones = ["Head"], ["Chest", "Neck"]

	asm.add(ellipsoid(P(*HEAD_C), HEAD_R, segs=48, rings=24), "skin", head_bones)
	for side in (1, -1):
		rot = Matrix.Rotation(math.radians(18.0 * side), 3, "Z")
		asm.add(ellipsoid(P(60 * side, 8, 153), (7.0, 10.0, 13.0), rot, 20, 12), "skin", head_bones)
	for part in build_hair():
		asm.add(part, "hair", head_bones)
	asm.add(tube([P(0, 4, 224), P(0, 4, 190)], [(19, 19), (19, 19)]), "skin", ["Neck", "Head", "Chest"], 4.0)

	jacket = rounded_box(P(0, 6, 284), (108, 92, 140), 34.0, taper_top=0.8)
	shirt = ellipsoid(P(0, -8, 228), (24.0, 34.0, 32.0), segs=32, rings=16)
	surf.add(jacket)
	surf.add(shirt)
	asm.add(jacket, "jacket", ["Hips", "Spine", "Chest"], 4.0)
	asm.add(shirt, "shirt", chest_bones, 4.0)

	# Back collar of the jacket.
	collar = [P(math.sin(math.radians(a)) * 21.0, 8.0 - math.cos(math.radians(a)) * 23.0, 212.0 - 3.0 * (1 - math.cos(math.radians(a))))
		for a in range(70, 291, 10)]
	asm.add(tube(collar, [(4.5, 4.5)] * len(collar), segs=12), "jacket", chest_bones, 4.0)

	for side in (1, -1):
		lapel = decal(lambda u, v, s=side: (
			s * ((20 + (2 - 20) * v) * (1 - u) + (34 + (10 - 34) * v) * u),
			(208 + (268 - 208) * v) * (1 - u) + (226 + (276 - 226) * v) * u,
		), 12, 4, surf, 1.5, 4.0)
		asm.add(lapel, "jacket", chest_bones, 4.0)
		shirt_collar = decal(lambda u, v, s=side: (
			s * ((4 + 2 * v) * (1 - u) + (19 - 3 * v) * u),
			(205 + 16 * v) * (1 - u) + (206 + 8 * v) * u,
		), 3, 3, surf, 1.0, 3.0)
		asm.add(shirt_collar, "shirt", chest_bones, 4.0)

	def tie_shape(u, v):
		w = 4.0 + 3.0 * min(v / 0.85, 1.0)
		if v > 0.85:
			w *= (1.0 - v) / 0.15
		return ((u - 0.5) * 2.0 * w, 222 + 48 * v)

	tie = decal(tie_shape, 10, 2, surf, 1.5, 3.0)
	knot = ellipsoid(P(0, surf.depth(0, 216, -40) - 2.5, 216), (6.0, 4.0, 6.5), segs=16, rings=10)
	asm.add(tie, "tie", chest_bones, 4.0)
	asm.add(knot, "tie", chest_bones, 4.0)

	for side, name in ((1, "Left"), (-1, "Right")):
		s, e, w, h, down = arm_joints(side)
		arm_bones = [name + "Shoulder", name + "UpperArm", name + "LowerArm", name + "Hand"]
		asm.add(tube([s - down * 8 * PX, s, e, w], [(20, 20), (19, 19), (16.5, 16.5), (15, 15)]), "jacket", arm_bones, 8.0)
		asm.add(tube([w - down * 3 * PX, w + down * 4 * PX], [(13.5, 13.5), (13.5, 13.5)], segs=16), "shirt", [name + "Hand"])
		across = Vector((0.0, -1.0, 0.0))
		palm = down.cross(across).normalized()
		rot = Matrix((palm, across, down)).transposed()
		asm.add(ellipsoid(w + down * 13 * PX, (7.5, 11.0, 13.0), rot, 24, 14), "skin", [name + "Hand"])
		asm.add(ellipsoid(w + down * 8 * PX + across * 9 * PX, (4.0, 4.0, 8.0), rot, 16, 10), "skin", [name + "Hand"])

		leg_bones = ["Hips", name + "UpperLeg", name + "LowerLeg", name + "Foot"]
		asm.add(tube([P(27 * side, 4, 318), P(27 * side, 4, 396), P(27 * side, 6, 452)],
			[(23, 27), (21, 24), (19, 21)], ref=Vector((side, 0.0, 0.0))), "trousers", leg_bones, 8.0)
		asm.add(rounded_box(P(27 * side, -12, 465), (40, 64, 28), 12.0, taper_top=0.85), "shoes",
			[name + "Foot", name + "Toes"], 6.0)
	asm.add(ellipsoid(P(0, 6, 340), (44.0, 38.0, 20.0)), "trousers", ["Hips", "LeftUpperLeg", "RightUpperLeg"], 6.0)
	return asm.finish("WisssBody", arm)


def build_face(arm):
	"""Eyes and mouth in one mesh, so expressions are shape keys."""
	bm = bmesh.new()
	features = []  # (name, first_vert, last_vert, centre, rotation)
	for name, x, y, radii in (("eye_l", 30, 146, (4.2, 1.8, 5.2)), ("eye_r", -30, 146, (4.2, 1.8, 5.2)), ("mouth", 0, 171, (7.5, 1.5, 1.2))):
		c, n = head_surface(x, y, 0.6)
		rot = Vector((0.0, -1.0, 0.0)).rotation_difference(n).to_matrix()
		part = ellipsoid(c, radii, rot, 20, 12)
		me = bpy.data.meshes.new("tmp")
		part.to_mesh(me)
		part.free()
		v0 = len(bm.verts)
		f0 = len(bm.faces)
		bm.from_mesh(me)
		bpy.data.meshes.remove(me)
		bm.faces.ensure_lookup_table()
		for i in range(f0, len(bm.faces)):
			bm.faces[i].material_index = 0 if name.startswith("eye") else 1
		features.append((name, v0, len(bm.verts), c, rot))
	me = bpy.data.meshes.new("WisssFace")
	bm.to_mesh(me)
	bm.free()
	me.materials.append(MATERIALS["eyes"])
	me.materials.append(MATERIALS["mouth"])
	for poly in me.polygons:
		poly.use_smooth = True
	ob = bpy.data.objects.new("WisssFace", me)
	bpy.context.scene.collection.objects.link(ob)
	ob.shape_key_add(name="Basis", from_mix=False)

	def key(name, fn):
		sk = ob.shape_key_add(name=name, from_mix=False)
		for feat, v0, v1, c, rot in features:
			inv = rot.inverted()
			for i in range(v0, v1):
				local = inv @ (me.vertices[i].co - c)
				local = fn(feat, local)
				sk.data[i].co = c + rot @ local

	def blink(feat, l):
		if feat.startswith("eye"):
			return Vector((l.x, l.y, l.z * 0.12 - 1.5 * PX))
		return l

	def wide(feat, l):
		return l * 1.35 if feat.startswith("eye") else l

	def mouth_open(feat, l):
		return Vector((l.x * 0.75, l.y, l.z * 6.0 - 2.0 * PX)) if feat == "mouth" else l

	def mouth_o(feat, l):
		return Vector((l.x * 0.5, l.y, l.z * 4.0 - 1.0 * PX)) if feat == "mouth" else l

	def smile(feat, l):
		return Vector((l.x * 1.1, l.y, l.z + (l.x / PX / 7.5) ** 2 * 2.5 * PX)) if feat == "mouth" else l

	def frown(feat, l):
		return Vector((l.x, l.y, l.z - (l.x / PX / 7.5) ** 2 * 2.5 * PX)) if feat == "mouth" else l

	key("Blink", blink)
	key("EyesWide", wide)
	key("MouthOpen", mouth_open)
	key("MouthO", mouth_o)
	key("Smile", smile)
	key("Frown", frown)
	ob.vertex_groups.new(name="Head").add(list(range(len(me.vertices))), 1.0, "REPLACE")
	ob.parent = arm
	ob.modifiers.new("Armature", "ARMATURE").object = arm
	return ob


def build_props():
	bm = rounded_box(Vector(), (28, 9, 40), 2.5)
	cash_print = rounded_box(D(0, -4.7, 0), (19, 1.2, 30), 0.5)
	cash = finish_prop("Cash", [(bm, "cash"), (cash_print, "cash_print")])
	handle = tube([D(0, 0, -18), D(0, 0, 14)], [(3.6, 3.6), (4.6, 4.6)], segs=16)
	band = tube([D(0, 0, 13), D(0, 0, 17)], [(5.6, 5.6), (5.6, 5.6)], segs=16)
	grill = ellipsoid(D(0, 0, 25), (9.0, 9.0, 9.5), segs=24, rings=14)
	mic = finish_prop("Mic", [(handle, "mic"), (band, "mic"), (grill, "grill")])
	return cash, mic


def finish_prop(name, parts):
	asm = bmesh.new()
	for part, mat in parts:
		me = bpy.data.meshes.new("tmp")
		part.to_mesh(me)
		part.free()
		f0 = len(asm.faces)
		asm.from_mesh(me)
		bpy.data.meshes.remove(me)
		asm.faces.ensure_lookup_table()
		for i in range(f0, len(asm.faces)):
			asm.faces[i].material_index = MAT_ORDER.index(mat)
	me = bpy.data.meshes.new(name)
	asm.to_mesh(me)
	asm.free()
	for mat in MAT_ORDER:
		me.materials.append(MATERIALS[mat])
	for poly in me.polygons:
		poly.use_smooth = True
	ob = bpy.data.objects.new(name, me)
	bpy.context.scene.collection.objects.link(ob)
	return ob


# --- poses --------------------------------------------------------------------------


def aim(arm, name, y_dir, z_hint):
	pb = arm.pose.bones[name]
	m = frame(y_dir, z_hint).to_4x4()
	m.translation = pb.head
	pb.matrix = m
	bpy.context.view_layer.update()


def two_bone(arm, side_name, hand_centre, hand_dir, hand_z, pole):
	pb = arm.pose.bones[side_name + "UpperArm"]
	s = pb.head.copy()
	l1, l2 = UPPER_ARM * PX, LOWER_ARM * PX
	w = hand_centre - hand_dir.normalized() * 13 * PX
	axis = w - s
	d = min(axis.length, (l1 + l2) * 0.999)
	axis.normalize()
	a = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
	h = math.sqrt(max(l1 * l1 - a * a, 0.0))
	pp = pole - s
	pp = (pp - axis * axis.dot(pp)).normalized()
	e = s + axis * a + pp * h
	w = s + axis * d
	aim(arm, side_name + "UpperArm", e - s, Vector((0.0, -1.0, 0.0)))
	aim(arm, side_name + "LowerArm", w - e, Vector((0.0, 0.0, 1.0)))
	aim(arm, side_name + "Hand", hand_dir, hand_z)


def clear_pose(arm):
	for pb in arm.pose.bones:
		pb.matrix_basis = Matrix()
	bpy.context.view_layer.update()


def key_pose(arm, action_name):
	act = bpy.data.actions.new(action_name)
	act.use_fake_user = True
	arm.animation_data.action = act
	for pb in arm.pose.bones:
		pb.keyframe_insert("rotation_quaternion", frame=1)
		pb.keyframe_insert("location", frame=1)
	return act


def hold_pose(arm):
	clear_pose(arm)
	for side, name in ((1, "Left"), (-1, "Right")):
		two_bone(arm, name, P(19 * side, -62, 284), D(-0.45 * side, -0.85, 0.25), Vector((0.0, 0.0, 1.0)),
			P(95 * side, 40, 310))
	return key_pose(arm, "Hold")


def talk_pose(arm):
	clear_pose(arm)
	two_bone(arm, "Right", P(-10, -72, 214), D(1.0, -0.2, 0.1), D(0.1, -0.25, 1.0), P(-95, 30, 300))
	aim(arm, "LeftUpperArm", D(0.22, 0.05, -1.0), Vector((0.0, -1.0, 0.0)))
	aim(arm, "LeftLowerArm", D(0.15, -0.35, -1.0), Vector((0.0, -1.0, 0.0)))
	aim(arm, "LeftHand", D(0.1, -0.3, -1.0), Vector((0.0, -1.0, 0.0)))
	return key_pose(arm, "Talk")


def hand_centre(arm, name):
	pb = arm.pose.bones[name]
	return pb.head + (pb.tail - pb.head).normalized() * 13 * PX, pb.matrix.to_3x3()


def attach(prop, arm, bone, world):
	prop.parent = arm
	prop.parent_type = "BONE"
	prop.parent_bone = bone
	bpy.context.view_layer.update()
	prop.matrix_world = world
	bpy.context.view_layer.update()


# --- preview --------------------------------------------------------------------------


def setup_preview_scene():
	scene = bpy.context.scene
	scene.render.engine = "CYCLES"
	scene.cycles.device = "CPU"
	scene.cycles.samples = 24
	scene.cycles.use_denoising = True
	scene.render.resolution_x = scene.render.resolution_y = 512
	scene.view_settings.view_transform = "Standard"
	scene.render.use_freestyle = True
	scene.render.line_thickness_mode = "ABSOLUTE"
	scene.render.line_thickness = 1.3
	scene.render.film_transparent = True
	world = bpy.data.worlds.new("bg")
	world.use_nodes = True
	world.node_tree.nodes["Background"].inputs["Color"].default_value = (1.0, 1.0, 1.0, 1.0)
	world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.45
	scene.world = world
	floor = bpy.data.meshes.new("floor")
	floor.from_pydata([(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)], [], [(0, 1, 2, 3)])
	fob = bpy.data.objects.new("PreviewFloor", floor)
	fob.is_shadow_catcher = True
	fmat = make_material("floor", (225, 225, 222), 0.9)
	floor.materials.append(fmat)
	scene.collection.objects.link(fob)
	outlined = bpy.data.collections.new("WisssPreviewOutline")
	scene.collection.children.link(outlined)
	for ob in bpy.data.objects:
		if ob.type == "MESH" and ob is not fob:
			outlined.objects.link(ob)
	for lineset in bpy.context.view_layer.freestyle_settings.linesets:
		lineset.linestyle = bpy.data.linestyles.new("outline")
		lineset.linestyle.color = (0.02, 0.02, 0.02)
		lineset.select_crease = False
		lineset.select_by_collection = True
		lineset.collection = outlined
	for name, loc, energy, size in (("Key", (-2.5, -3.5, 3.5), 250.0, 3.0), ("Fill", (3.0, -2.0, 1.5), 60.0, 4.0), ("Rim", (0.5, 3.0, 3.0), 90.0, 2.0)):
		light = bpy.data.lights.new(name, "AREA")
		light.energy, light.size = energy, size
		lob = bpy.data.objects.new(name, light)
		lob.location = loc
		lob.rotation_euler = (Vector((0, 0, 0.85)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
		scene.collection.objects.link(lob)
	cam_data = bpy.data.cameras.new("cam")
	cam_data.lens = 85.0
	cam = bpy.data.objects.new("PreviewCam", cam_data)
	cam.location = (0.0, -4.7, 0.95)
	cam.rotation_euler = (Vector((0, 0, 0.853)) - cam.location).to_track_quat("-Z", "Y").to_euler()
	scene.collection.objects.link(cam)
	scene.camera = cam
	return [fob, cam]


def render(path):
	bpy.context.scene.render.filepath = path
	bpy.ops.render.render(write_still=True)


def main():
	out = arg("out", "models/wisss")
	preview = arg("preview")
	bpy.ops.wm.read_factory_settings(use_empty=True)
	for name, rgb in COLORS.items():
		MATERIALS[name] = make_material(name, rgb, 0.35 if name in ("eyes", "mic") else 0.62)
	define_bones()
	arm = build_armature()
	arm.animation_data_create()
	build_body(arm)
	build_face(arm)
	cash, mic = build_props()

	talk = talk_pose(arm)
	centre, rot = hand_centre(arm, "RightHand")
	attach(mic, arm, "RightHand", Matrix.Translation(centre) @ rot.to_4x4())

	hold = hold_pose(arm)
	cash_world = Matrix.Translation(P(0, -66, 283))
	attach(cash, arm, "RightHand", cash_world)

	os.makedirs(out, exist_ok=True)
	if preview:
		os.makedirs(preview, exist_ok=True)
		extras = setup_preview_scene()
		mic.hide_render = True
		for angle in (0, 90, 180, 270):
			arm.rotation_euler.z = math.radians(angle)
			render(os.path.join(preview, "turn_%03d.png" % angle))
		arm.rotation_euler.z = 0.0
		arm.animation_data.action = talk
		bpy.context.scene.frame_set(1)
		mic.hide_render, cash.hide_render = False, True
		render(os.path.join(preview, "talk.png"))
		mic.hide_render = cash.hide_render = False
		arm.animation_data.action = hold
		for ob in extras:
			bpy.data.objects.remove(ob)
		bpy.data.collections.remove(bpy.data.collections["WisssPreviewOutline"])
		bpy.context.scene.render.use_freestyle = False

	clear_pose(arm)
	arm.animation_data.action = None
	bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(os.path.join(out, "wisss.blend")))
	bpy.ops.export_scene.gltf(
		filepath=os.path.abspath(os.path.join(out, "wisss.glb")),
		export_format="GLB",
		export_apply=True,
		export_animations=True,
		export_animation_mode="ACTIONS",
		export_morph=True,
		export_skins=True,
	)


main()
