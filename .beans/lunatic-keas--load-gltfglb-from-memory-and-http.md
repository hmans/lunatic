---
# lunatic-keas
title: Load GLTF/GLB from memory and HTTP
status: todo
type: feature
created_at: 2026-04-04T16:48:45Z
updated_at: 2026-04-04T16:48:45Z
---

Zig-first: add loadGltfFromMemory(bytes) using cgltf_parse instead of cgltf_parse_file. Then add HTTP fetching (likely via libcurl) to download GLB bytes. Lua: load_gltf_url(url). Depends on existing GLTF loader.
