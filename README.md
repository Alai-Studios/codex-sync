# Codex Sync GitHub Action

A GitHub Action that intelligently syncs files from your repository to a Spark Codex. It compares local files with existing Codex content and only uploads changes.

## Features

- **Smart diffing**: Compares files by name and modification date
- **Minimal API calls**: Only uploads new/changed files
- **Dry run mode**: Preview changes before applying
- **Git-aware**: Uses git commit timestamps for accurate change detection
- **Multiple file types**: Supports PDF, Markdown, images, audio, and video

## Usage

### Basic Usage

```yaml
name: Sync Docs to Codex

on:
  push:
    branches: [main]
    paths:
      - 'docs/**'

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Required for git timestamps

      - uses: Alai-Studios/codex-sync@v1
        with:
          spark_api_key: ${{ secrets.SPARK_API_KEY }}
          codex_id: 'cdx_your-codex-id'
          directory: 'docs'
```

### Full Example with All Options

```yaml
- uses: Alai-Studios/codex-sync@v1
  with:
    spark_api_key: ${{ secrets.SPARK_API_KEY }}
    codex_id: 'cdx_your-codex-id'
    directory: 'docs'
    api_base_url: 'https://api.spark.my.alaispark.app'
    file_extensions: 'md,mdx,pdf,png'
    dry_run: 'false'
    delete_removed: 'true'
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `spark_api_key` | Spark API key with `contents:write` permission | Yes | - |
| `codex_id` | Target Codex ID (e.g., `cdx_abc123...`) | Yes | - |
| `directory` | Directory to sync (relative to repo root) | Yes | - |
| `api_base_url` | Spark API base URL | No | `https://api.spark.my.alaispark.app` |
| `file_extensions` | Comma-separated file extensions to sync | No | `pdf,txt,md,mdx,png,jpg,jpeg,webp,gif,mp3,mp4` |
| `dry_run` | Preview changes without applying | No | `false` |
| `delete_removed` | Delete Codex files not in repo | No | `true` |

## Outputs

| Output | Description |
|--------|-------------|
| `files_added` | Number of new files uploaded |
| `files_updated` | Number of files updated |
| `files_deleted` | Number of files deleted |
| `files_unchanged` | Number of unchanged files |

## Diff Output

The action prints a clear diff summary before syncing:

```
════════════════════════════════════════════════════════════
                     Codex Sync Diff
════════════════════════════════════════════════════════════

 + ADD (2 files)
   • getting-started.md
   • api-reference.md

 ↻ UPDATE (1 file)
   • installation.md
     local: 2025-12-30 → codex: 2025-12-15

 - DELETE (1 file)
   • deprecated-guide.md

 = UNCHANGED (5 files)

════════════════════════════════════════════════════════════

📊 Summary: 9 total | +2 | ↻1 | -1 | =5
```

## Supported File Types

| Type | Extensions |
|------|------------|
| Documents | `.pdf`, `.txt`, `.md`, `.mdx` |
| Images | `.png`, `.jpg`, `.jpeg`, `.webp`, `.gif` |
| Audio | `.mp3` |
| Video | `.mp4` |

## Requirements

- **Git history**: Use `actions/checkout@v4` with `fetch-depth: 0` for accurate timestamps
- **API permissions**: Service client needs `contents:write` permission on the organization
- **Runner tools**: Requires `curl`, `jq`, and `git` (pre-installed on GitHub runners)

## Getting a Spark API Key

1. Go to your Spark admin dashboard
2. Navigate to Settings → API Keys
3. Create a new service client with `contents:write` permission
4. Copy the access key and add it as a repository secret

## License

MIT
