import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

class GlbFile {
  late Map<String, dynamic> json;
  late Uint8List bin;

  GlbFile(this.json, this.bin);
}

/// ------------------------------------------------------------
/// 1. LOAD GLB
/// ------------------------------------------------------------
Future<GlbFile> loadGlb(String path) async {
  final bytes = await File(path).readAsBytes();
  final data = ByteData.sublistView(bytes);

  // Header
  final magic = data.getUint32(0, Endian.little);
  final version = data.getUint32(4, Endian.little);
  final length = data.getUint32(8, Endian.little);

  if (magic != 0x46546C67) throw Exception("Not a GLB file");
  if (version != 2) throw Exception("Only GLB v2 supported");
  if (length != bytes.length) throw Exception("Corrupt GLB");

  int offset = 12;

  // JSON chunk
  final jsonChunkLength = data.getUint32(offset, Endian.little);
  final jsonChunkType = data.getUint32(offset + 4, Endian.little);
  offset += 8;

  if (jsonChunkType != 0x4E4F534A) throw Exception("Missing JSON chunk");

  final jsonBytes = bytes.sublist(offset, offset + jsonChunkLength);
  final jsonText = utf8.decode(jsonBytes);
  final json = jsonDecode(jsonText);
  offset += jsonChunkLength;

  // BIN chunk
  final binChunkLength = data.getUint32(offset, Endian.little);
  final binChunkType = data.getUint32(offset + 4, Endian.little);
  offset += 8;

  if (binChunkType != 0x004E4942) throw Exception("Missing BIN chunk");

  final bin = bytes.sublist(offset, offset + binChunkLength);

  return GlbFile(json, Uint8List.fromList(bin));
}

/// ------------------------------------------------------------
/// 2. ROTATE ALL VERTEX POSITIONS
/// ------------------------------------------------------------
void rotateGlb(GlbFile glb, double degreesX, double degreesY, double degreesZ) {
  final radX = degreesX * pi / 180.0;
  final radY = degreesY * pi / 180.0;
  final radZ = degreesZ * pi / 180.0;

  // Rotation matrices
  List<List<double>> rotX = [
    [1, 0, 0],
    [0, cos(radX), -sin(radX)],
    [0, sin(radX), cos(radX)],
  ];

  List<List<double>> rotY = [
    [cos(radY), 0, sin(radY)],
    [0, 1, 0],
    [-sin(radY), 0, cos(radY)],
  ];

  List<List<double>> rotZ = [
    [cos(radZ), -sin(radZ), 0],
    [sin(radZ), cos(radZ), 0],
    [0, 0, 1],
  ];

  List<List<double>> mul(List<List<double>> A, List<List<double>> B) {
    List<List<double>> R = List.generate(3, (_) => List.filled(3, 0.0));
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        for (int k = 0; k < 3; k++) {
          R[i][j] += A[i][k] * B[k][j];
        }
      }
    }
    return R;
  }

  List<List<double>> M = mul(rotZ, mul(rotY, rotX));

  // Apply rotation to all POSITION accessors
  final accessors = glb.json["accessors"];
  final bufferViews = glb.json["bufferViews"];
  final bin = glb.bin;
  final bd = ByteData.sublistView(bin);

  for (int i = 0; i < accessors.length; i++) {
    final acc = accessors[i];
    if (acc["type"] != "VEC3") continue;
    if (acc["componentType"] != 5126) continue; // FLOAT32
    if (acc["name"] != null && acc["name"] != "POSITION") continue;

    final bv = bufferViews[acc["bufferView"]];
    final offset = (bv["byteOffset"] ?? 0) + (acc["byteOffset"] ?? 0);
    final count = acc["count"];
    final stride = bv["byteStride"] ?? 12;

    for (int v = 0; v < count; v++) {
      final base = offset + v * stride;

      double x = bd.getFloat32(base, Endian.little);
      double y = bd.getFloat32(base + 4, Endian.little);
      double z = bd.getFloat32(base + 8, Endian.little);

      double nx = M[0][0] * x + M[0][1] * y + M[0][2] * z;
      double ny = M[1][0] * x + M[1][1] * y + M[1][2] * z;
      double nz = M[2][0] * x + M[2][1] * y + M[2][2] * z;

      bd.setFloat32(base, nx, Endian.little);
      bd.setFloat32(base + 4, ny, Endian.little);
      bd.setFloat32(base + 8, nz, Endian.little);
    }
  }
}

/// ------------------------------------------------------------
/// 3. SAVE GLB
/// ------------------------------------------------------------
Future<void> saveGlb(GlbFile glb, String path) async {
  final jsonBytes = utf8.encode(jsonEncode(glb.json));
  final paddedJson = _padTo4(jsonBytes);
  final paddedBin = _padTo4(glb.bin);

  final totalLength =
      12 + 8 + paddedJson.length + 8 + paddedBin.length;

  final out = BytesBuilder();

  // Header
  out.add(_u32(0x46546C67)); // magic
  out.add(_u32(2));          // version
  out.add(_u32(totalLength));

  // JSON chunk
  out.add(_u32(paddedJson.length));
  out.add(_u32(0x4E4F534A));
  out.add(paddedJson);

  // BIN chunk
  out.add(_u32(paddedBin.length));
  out.add(_u32(0x004E4942));
  out.add(paddedBin);

  await File(path).writeAsBytes(out.toBytes());
}

Uint8List _padTo4(List<int> bytes) {
  final pad = (4 - (bytes.length % 4)) % 4;
  return Uint8List.fromList([...bytes, ...List.filled(pad, 0)]);
}

Uint8List _u32(int v) {
  final b = ByteData(4);
  b.setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

/// ------------------------------------------------------------
/// 4. EXAMPLE USAGE
/// ------------------------------------------------------------
Future<void> main() async {
  final glb = await loadGlb("input.glb");

  rotateGlb(glb, 0, 90, 0); // rotate 90° around Y

  await saveGlb(glb, "output_rotated.glb");
}
