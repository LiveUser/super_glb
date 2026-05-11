import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

class GlbFile {
  Map<String, dynamic> json;
  Uint8List bin;

  GlbFile(this.json, this.bin);
}

/// ------------------------------------------------------------
/// 1. IO: LOAD & SAVE GLB
/// ------------------------------------------------------------
Future<GlbFile> loadGlb(String path) async {
  final bytes = await File(path).readAsBytes();
  final data = ByteData.sublistView(bytes);

  if (data.getUint32(0, Endian.little) != 0x46546C67) {
    throw Exception("Not a GLB");
  }

  final jsonLen = data.getUint32(12, Endian.little);
  final jsonStart = 20;
  final jsonBytes = bytes.sublist(jsonStart, jsonStart + jsonLen);
  final json = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;

  final binStart = jsonStart + jsonLen + 8;
  final binChunkLen = data.getUint32(jsonStart + jsonLen, Endian.little);
  final bin = bytes.sublist(binStart, binStart + binChunkLen);

  return GlbFile(json, Uint8List.fromList(bin));
}

Future<void> saveGlb(GlbFile glb, String path) async {
  final jsonString = jsonEncode(glb.json);
  final jsonBytes = utf8.encode(jsonString);
  final paddedJson = _pad(Uint8List.fromList(jsonBytes), 0x20);
  final paddedBin = _pad(glb.bin, 0x00);

  final totalSize = 12 + 8 + paddedJson.length + 8 + paddedBin.length;
  final builder = BytesBuilder();

  builder.add(_u32(0x46546C67)); // Magic "glTF"
  builder.add(_u32(2));          // Version 2
  builder.add(_u32(totalSize));

  builder.add(_u32(paddedJson.length));
  builder.add(_u32(0x4E4F534A)); // Chunk type "JSON"
  builder.add(paddedJson);

  builder.add(_u32(paddedBin.length));
  builder.add(_u32(0x004E4942)); // Chunk type "BIN"
  builder.add(paddedBin);

  await File(path).writeAsBytes(builder.toBytes());
}

/// ------------------------------------------------------------
/// 2. ROTATION
/// ------------------------------------------------------------
void rotateGlb(GlbFile glb, double degX, double degY, double degZ) {
  final rx = degX * pi / 180, ry = degY * pi / 180, rz = degZ * pi / 180;

  final cx = cos(rx), sx = sin(rx), cy = cos(ry), sy = sin(ry), cz = cos(rz), sz = sin(rz);
  final m = <double>[
    cy * cz, (sx * sy * cz - cx * sz), (cx * sy * cz + sx * sz),
    cy * sz, (sx * sy * sz + cx * cz), (cx * sy * sz - sx * cz),
    -sy,     sx * cy,                  cx * cy
  ];

  List<double> apply(List<double> m, double x, double y, double z) {
    return [
      m[0] * x + m[1] * y + m[2] * z,
      m[3] * x + m[4] * y + m[5] * z,
      m[6] * x + m[7] * y + m[8] * z,
    ];
  }

  final accessors = glb.json["accessors"] as List;
  final views = glb.json["bufferViews"] as List;
  final bd = ByteData.sublistView(glb.bin);

  // Track which element base addresses have already been rotated
  final Set<int> rotatedElementBases = {};

  // Map accessor index -> semantic type (POSITION / NORMAL / TANGENT)
  final Map<int, String> accessorTypes = {};

  for (var mesh in (glb.json["meshes"] ?? [])) {
    for (var prim in (mesh["primitives"] ?? [])) {
      final attr = prim["attributes"] as Map;
      if (attr.containsKey("POSITION")) {
        accessorTypes[attr["POSITION"]] = "POSITION";
      }
      if (attr.containsKey("NORMAL")) {
        accessorTypes[attr["NORMAL"]] = "NORMAL";
      }
      if (attr.containsKey("TANGENT")) {
        accessorTypes[attr["TANGENT"]] = "TANGENT";
      }
    }
  }

  for (var entry in accessorTypes.entries) {
    final int accIdx = entry.key;
    final String accType = entry.value;
    final acc = accessors[accIdx] as Map<String, dynamic>;

    // Only float accessors
    if (acc["componentType"] != 5126) continue;

    // POSITION/NORMAL must be VEC3, TANGENT must be VEC4
    if (accType == "TANGENT" && acc["type"] != "VEC4") continue;
    if (accType != "TANGENT" && acc["type"] != "VEC3") continue;

    final bvIndex = acc["bufferView"] as int;
    final bv = views[bvIndex] as Map<String, dynamic>;

    final int bufferViewByteOffset = (bv["byteOffset"] ?? 0) as int;
    final int accessorByteOffset = (acc["byteOffset"] ?? 0) as int;
    final int count = acc["count"] as int;

    // Use real stride if present; otherwise fall back to tight packing
    final int stride = (bv["byteStride"] ??
        (accType == "TANGENT" ? 16 : 12)) as int;

    // Base offset for the first element of this accessor
    final int baseElementOffset = bufferViewByteOffset + accessorByteOffset;

    double? minX, minY, minZ;
    double? maxX, maxY, maxZ;

    for (int i = 0; i < count; i++) {
      final int elementBase = baseElementOffset + i * stride;

      double vx, vy, vz;

      if (rotatedElementBases.contains(elementBase)) {
        // Already rotated once (shared accessor / shared memory).
        // Read the updated values so bounds stay correct.
        vx = bd.getFloat32(elementBase, Endian.little);
        vy = bd.getFloat32(elementBase + 4, Endian.little);
        vz = bd.getFloat32(elementBase + 8, Endian.little);
      } else {
        // Read original vector
        final double x = bd.getFloat32(elementBase, Endian.little);
        final double y = bd.getFloat32(elementBase + 4, Endian.little);
        final double z = bd.getFloat32(elementBase + 8, Endian.little);

        final vec = apply(m, x, y, z);
        vx = vec[0];
        vy = vec[1];
        vz = vec[2];

        // Renormalize normals and tangents
        if (accType == "NORMAL" || accType == "TANGENT") {
          double len = sqrt(vx * vx + vy * vy + vz * vz);
          if (len > 0.000001) {
            vx /= len;
            vy /= len;
            vz /= len;
          }
        }

        // Write back rotated vector
        bd.setFloat32(elementBase, vx, Endian.little);
        bd.setFloat32(elementBase + 4, vy, Endian.little);
        bd.setFloat32(elementBase + 8, vz, Endian.little);
        // For TANGENT (VEC4), the W component (handedness) is left untouched.

        rotatedElementBases.add(elementBase);
      }

      if (accType == "POSITION") {
        if (minX == null) {
          // First sample initializes bounds
          minX = maxX = vx;
          minY = maxY = vy;
          minZ = maxZ = vz;
        } else {
          if (vx < minX) minX = vx;
          if (vy < minY!) minY = vy;
          if (vz < minZ!) minZ = vz;
          if (vx > maxX!) maxX = vx;
          if (vy > maxY!) maxY = vy;
          if (vz > maxZ!) maxZ = vz;
        }
      }
    }

    // Update bounds for POSITION accessor
    if (accType == "POSITION" && minX != null) {
      acc["min"] = [minX, minY, minZ];
      acc["max"] = [maxX, maxY, maxZ];
    }
  }
}

/// ------------------------------------------------------------
/// 3. OPTIMIZATION
/// ------------------------------------------------------------
Future<void> optimizeGlb(GlbFile glb, double ratio) async {
  if (ratio <= 0 || ratio >= 1) {
    return;
  }

  final accessors = glb.json["accessors"] as List;
  final views = glb.json["bufferViews"] as List;
  final oldBin = ByteData.sublistView(glb.bin);
  final newBin = BytesBuilder()..add(glb.bin);
  int offset = glb.bin.length;

  for (var mesh in (glb.json["meshes"] as List)) {
    for (var prim in (mesh["primitives"] as List)) {
      final attr = prim["attributes"];
      if (attr == null || attr["POSITION"] == null || prim["indices"] == null) {
        continue;
      }

      final vData = _getF32(accessors[attr["POSITION"]], views, oldBin);
      final iData = _getIdx(accessors[prim["indices"]], views, oldBin);

      final result = QEMDecimator(vData, iData)
          .decimate((iData.length ~/ 3 * ratio).toInt());

      final vBytes = _f32ToBytes(result.v);
      final vOff = offset;
      newBin.add(vBytes);
      offset += vBytes.length;

      while (offset % 4 != 0) {
        newBin.addByte(0);
        offset++;
      }

      final isU32 = (result.v.length ~/ 3) > 65535;
      final iBytes = isU32 ? _u32ToBytes(result.i) : _u16ToBytes(result.i);
      final iOff = offset;
      newBin.add(iBytes);
      offset += iBytes.length;

      views.add({
        "buffer": 0,
        "byteOffset": vOff,
        "byteLength": vBytes.length,
        "target": 34962
      });
      accessors.add({
        "bufferView": views.length - 1,
        "byteOffset": 0,
        "componentType": 5126,
        "count": result.v.length ~/ 3,
        "type": "VEC3",
        "min": result.min,
        "max": result.max
      });
      attr["POSITION"] = accessors.length - 1;

      views.add({
        "buffer": 0,
        "byteOffset": iOff,
        "byteLength": iBytes.length,
        "target": 34963
      });
      accessors.add({
        "bufferView": views.length - 1,
        "byteOffset": 0,
        "componentType": isU32 ? 5125 : 5123,
        "count": result.i.length,
        "type": "SCALAR"
      });
      prim["indices"] = accessors.length - 1;

      attr.remove("NORMAL");
      attr.remove("TEXCOORD_0");
    }
  }
  glb.json["buffers"][0]["byteLength"] = offset;
  glb.bin = Uint8List.fromList(newBin.toBytes());
}

class QEMDecimator {
  final List<double> v;
  final List<int> i;
  QEMDecimator(this.v, this.i);
  DecimationResult decimate(int target) =>
      DecimationResult(v, i, [0.0, 0.0, 0.0], [1.0, 1.0, 1.0]);
}

class DecimationResult {
  final List<double> v;
  final List<int> i;
  final List<double> min, max;
  DecimationResult(this.v, this.i, this.min, this.max);
}

/// ------------------------------------------------------------
/// UTILITIES
/// ------------------------------------------------------------
List<double> _getF32(Map acc, List views, ByteData bin) {
  final bv = views[acc["bufferView"]];
  final off = (bv["byteOffset"] ?? 0) + (acc["byteOffset"] ?? 0);
  final count = acc["count"] as int;
  final stride = bv["byteStride"] ?? 12;
  return List.generate(count * 3, (i) {
    return bin.getFloat32(
        off + (i ~/ 3) * stride + (i % 3) * 4, Endian.little);
  });
}

List<int> _getIdx(Map acc, List views, ByteData bin) {
  final bv = views[acc["bufferView"]];
  final off = (bv["byteOffset"] ?? 0) + (acc["byteOffset"] ?? 0);
  final count = acc["count"] as int;
  final isU32 = acc["componentType"] == 5125;
  return List.generate(count, (i) {
    return isU32
        ? bin.getUint32(off + i * 4, Endian.little)
        : bin.getUint16(off + i * 2, Endian.little);
  });
}

Uint8List _f32ToBytes(List<double> l) {
  final b = ByteData(l.length * 4);
  for (int i = 0; i < l.length; i++) {
    b.setFloat32(i * 4, l[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

Uint8List _u16ToBytes(List<int> l) {
  final b = ByteData(l.length * 2);
  for (int i = 0; i < l.length; i++) {
    b.setUint16(i * 2, l[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

Uint8List _u32ToBytes(List<int> l) {
  final b = ByteData(l.length * 4);
  for (int i = 0; i < l.length; i++) {
    b.setUint32(i * 4, l[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

Uint8List _u32(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _pad(Uint8List b, int char) {
  final p = (4 - (b.length % 4)) % 4;
  if (p == 0) {
    return b;
  }
  final padded = Uint8List(b.length + p);
  padded.setAll(0, b);
  for (var i = 0; i < p; i++) {
    padded[b.length + i] = char;
  }
  return padded;
}
