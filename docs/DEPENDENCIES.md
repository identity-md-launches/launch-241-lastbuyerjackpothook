# Vendored source provenance

Sources are a reduced, unmodified dependency snapshot from [Identity-md/univ4hook-start-template at 8254234c70e74de59f32ad6ff524da59a59aa52a](https://github.com/Identity-md/univ4hook-start-template/tree/8254234c70e74de59f32ad6ff524da59a59aa52a). Only the compile dependency closure, forge-std's source directory, and HookMiner are retained. There are no submodules, downloaded compiler binaries, node packages, or install steps. Unused upstream tests and duplicate dependency trees were removed. The retained files themselves are the build inputs; upstream changes cannot affect this project.

- `lib/forge-std/src`: Foundry test support.
- `lib/uniswap-hooks/src/base/BaseHook.sol`: OpenZeppelin BaseHook, whose own source identifies version 1.2.0.
- `lib/uniswap-hooks/lib/v4-core`: real PoolManager, its interfaces/libraries, and imported test routers/harness utilities.
- `lib/uniswap-hooks/lib/openzeppelin-contracts`: ERC20, ReentrancyGuard and their imports from the template's pinned snapshot.
- `lib/uniswap-hooks/lib/v4-core/lib/solmate`: Owned and mock ERC20 support required by real core and its tests.
- `lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol`: production CREATE2 mining helper, retained for launch tooling.

[vendor-sha256.json](vendor-sha256.json) records SHA-256 for every retained dependency file. Individual upstream dependency commits were not recorded by the flattened template; the template commit plus file hashes identifies the exact source snapshot without inventing upstream revisions.

`test/BaseHookTest.sol` is adapted from the same template: it constructs the actual no-argument LBUY token rather than its configurable example token. Tests select LastBuyerJackpotHook via the harness's artifact override. `src/LaunchToken.sol` is adapted from the template to fix name/symbol, remove constructor parameters, and mint to the deployer. Contracts and test behavior outside these adaptations are implemented in this assignment.

Source SPDX identifiers retain their upstream license declarations. [licenses/](licenses/) includes the respective upstream license texts; [licenses/provenance.json](licenses/provenance.json) pins the source URLs and hashes of those license texts. **Those license-text revisions are not claims about source-code revisions.** Core's BUSL terms apply to the applicable core files; test use is not an assertion of authorization for an unrelated production fork. This launch uses the existing Sepolia manager.

To verify the vendored file hashes offline with Python's standard library:

```sh
python3 - <<'PY'
import hashlib, json, pathlib
files = json.loads(pathlib.Path('docs/vendor-sha256.json').read_text())
for name, expected in files.items():
    assert hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() == expected, name
print(f'{len(files)} dependency files verified')
PY
```
