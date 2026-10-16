# gcp-blender-render

A Claude Code skill: render Blender scenes on a Google Cloud GPU VM (L4 Spot) from the command line with
`gcloud`. See [SKILL.md](SKILL.md) for the workflow and the lessons learned, and
[scripts/gcp_render.ps1](scripts/gcp_render.ps1) for the helper script (quota, create, setup, render, fetch, delete).

Install: copy this folder to `~/.claude/skills/gcp-blender-render`.

Note: `create` starts billing. The script does a dry run unless `-Yes` is passed.
