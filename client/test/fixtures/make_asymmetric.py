"""Build a small public-domain static GLB for the real loader and CSP tests."""
import hashlib
import json
import pathlib
import struct
import zlib

HERE = pathlib.Path(__file__).parent


def chunk(kind, data):
    data += b' ' * (-len(data) % 4) if kind == b'JSON' else b'\0' * (-len(data) % 4)
    return struct.pack('<I', len(data)) + kind + data


def png():
    def part(tag, payload):
        body = tag + payload
        return struct.pack('>I', len(payload)) + body + struct.pack('>I', zlib.crc32(body))
    return (b'\x89PNG\r\n\x1a\n' +
            part(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 6, 0, 0, 0)) +
            part(b'IDAT', zlib.compress(b''.join(b'\0' + b'\xe8\x9f\x41\xff' * 2
                                               for _ in range(2)))) +
            part(b'IEND', b''))


bin_data = bytearray()
views = []


def add(data):
    while len(bin_data) % 4:
        bin_data.append(0)
    offset = len(bin_data)
    bin_data.extend(data)
    views.append({'buffer': 0, 'byteOffset': offset, 'byteLength': len(data)})
    return len(views) - 1


positions = [
    (0.2, 0.0, -0.4), (1.2, 0.0, -0.4), (0.4, 1.4, 0.3),
    (-0.5, 0.2, 0.3), (0.3, 0.2, 0.3), (-0.2, 0.7, 0.5),
]
pos_views = [add(b''.join(struct.pack('<fff', *v) for v in positions[i:i + 3]))
             for i in (0, 3)]
uv_view = add(struct.pack('<ffffff', 0, 0, 1, 0, 0, 1))
image_view = add(png())
(HERE / 'texture.png').write_bytes(png())
accessors = []
for i, vv in enumerate(pos_views):
    vertices = positions[i * 3:i * 3 + 3]
    accessors.append({'bufferView': vv, 'componentType': 5126, 'count': 3,
                      'type': 'VEC3', 'min': list(map(min, zip(*vertices))),
                      'max': list(map(max, zip(*vertices)))})
accessors.append({'bufferView': uv_view, 'componentType': 5126,
                  'count': 3, 'type': 'VEC2'})
document = {
    'asset': {'version': '2.0', 'generator': 'Quod fixture generator'},
    'scene': 0, 'scenes': [{'nodes': [0]}],
    'nodes': [{'name': 'not-a-subject', 'extras': {'depicts': 'forged'},
               'children': [1, 2]},
              {'mesh': 0, 'name': 'red-piece'},
              {'mesh': 1, 'name': 'blue-piece', 'translation': [0.2, 0, -0.2]}],
    'meshes': [{'primitives': [{'attributes': {'POSITION': 0, 'TEXCOORD_0': 2},
                               'material': 0}]},
               {'primitives': [{'attributes': {'POSITION': 1}, 'material': 1}]}],
    'materials': [{'name': 'textured', 'pbrMetallicRoughness': {
        'baseColorTexture': {'index': 0}, 'metallicFactor': 0,
        'roughnessFactor': 0.8}},
                  {'name': 'blue', 'pbrMetallicRoughness': {
                      'baseColorFactor': [0.1, 0.3, 0.9, 1.0],
                      'metallicFactor': 0, 'roughnessFactor': 0.8}}],
    'textures': [{'source': 0}],
    'images': [{'bufferView': image_view, 'mimeType': 'image/png'}],
    'buffers': [{'byteLength': len(bin_data)}], 'bufferViews': views,
    'accessors': accessors,
}
body = chunk(b'JSON', json.dumps(document, separators=(',', ':')).encode())
body += chunk(b'BIN\0', bytes(bin_data))
glb = b'glTF' + struct.pack('<II', 2, 12 + len(body)) + body
digest = hashlib.sha256(glb).hexdigest()
(HERE / 'asymmetric.glb').write_bytes(glb)
(HERE / 'asymmetric.sha256').write_text(digest + '\n')
print(digest)
