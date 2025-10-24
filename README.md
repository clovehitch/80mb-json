# Test repo for NetBox Enterprise Data Source (GitHub-safe caps)

This tree mimics a typical structure for NetBox-managed files (scripts, reports, export templates, config contexts) plus large CSV/JSON data.

**Caps enforced by the generator:**
- No single file > 99 MB (default MAX_SINGLE_MB, adjustable).
- Total repo size < 900 MB by default (TOTAL_BUDGET_MB), so it stays below GitHub’s soft 1 GB guidance.

**Tips**
- In NetBox Data Source, set Path to `netbox/` so the `data/` tree is not scanned.
- To stress-test, move some large files under `netbox/` and re-sync (not recommended for production).
