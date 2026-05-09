# Super GLB
A dart glb manipulation software. Entirely developed by Copilot.
## GLB Rotation
~~~dart
GlbFile glbFile = await loadGlb("C:\\Users\\valen\\Downloads\\compressed\\8.0007.3j_low_poly.glb");
rotateGlb(
  glbFile, -90, 0, 0
);
await saveGlb(glbFile, "C:\\Users\\valen\\Downloads\\compressed\\8.0007.3j_low_poly_rotated.glb");
~~~