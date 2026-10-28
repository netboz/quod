# Actual M1a founding receipt

These bytes come from `gates-04`’s signed production journey. They identify a disposable local network. Complete sequential qualification is recorded separately in the campaign result.

[Canonical receipt](gates-04-founding.json), [public identity verification](gates-04-public-identity.json), [HTTPS operations](gates-04-founding.json.https.json), [endpoint/trust](gates-04-founding.json.trust.json).

| Slot | Exact namespace | Genesis anchor (hex) |
| --- | --- | --- |
| R | quod:root | `7433C07A518DFEA4940D9D8DE26F210C45F7D010A4468442FEC459B6D67E1247` |
| N | quod:node | `9AB236533E22ED1D75662C9341D615CF9DC4570D1D13A186CC7FEB2587CC3746` |
| AClass | quod:agent | `279CBD57E44A5A700C62D8C65AC0C7AB4BE379C1C442AE862218A52D74A4D41E` |
| G | quod:gui | `82882E7FF129D783818FC89368AC33F63ED58A5BD6EFAAAB93389E90850C66E1` |
| C | quod:controllers | `7480B7030BFF60E8E4894E0527F8D372E77BEF33B5DC4AED5C414CCC4431CE8F` |
| S | quod:space | `7564D20AF99BB2919A18E077ED3E60AA512886AD29523AC6DF6434DC236288BF` |
| UClass | quod:user | `3440A3ED13AAAE67EE1107EB5D2B7B529195B3FDFDD1F62EDF6442BECF2D8540` |

Root is not a catalogue row. Six catalogue identities plus root make seven foundations. One enrolled node history, two human histories and an unrelated agent history bring the total to eleven. Personal A and S0 are instances, not extra histories.

## Node and account identities

Enrolled node public key: `D179D3873609ECB6AEE35315FEDBB8743A2130B66FA35D44ABBD8ED6812189E3`.
Node namespace: `node:d179d3873609ecb6aee35315fedbb8743a2130b66fa35d44abbd8ed6812189e3`; anchor: `C10538656F0C6BAE64A2A7E15A42ED165012017B98FF5269959F6FD120A35B28`; instance: `me`.

### Account 1

Namespace: `human:ltQ_KKCP5MPXLYqsQHy2XuRU0QOOmQsb5-C5DebelbE`.
History anchor: `A10F39EAA369D65AB1DD5569BEE85D8BF05D5E045E7454C9F81D172CD28F8531`.
Human U: `me`; personal A: `personal`; S0: `<<"01M603MH7G628DNX42QRMB1DCJ">>`.
Explicit selected storage: `ontology_ref(human:ltQ_KKCP5MPXLYqsQHy2XuRU0QOOmQsb5-C5DebelbE, A10F39EAA369D65AB1DD5569BEE85D8BF05D5E045E7454C9F81D172CD28F8531)`.
Human public key: `2F82B732DB5C94CB5F038717D54E7B253EF28A67984248369D4912C01CE84FD4`.
Personal-agent public key: `E8699D6B0FC648FE08E41E74BB9EBF457891D9EEFBF2C612411F572D2F0ABDF1`.

The original setup operation names this exact U. Its immutable custody signature verifies against the enrolled executor for this exact A, none/0 prior assignment, destination and key. U and A keys differ. S0 is U-owned and parentless; its local space class belongs to this storage identity. The shared S anchor and pinned source hash are recorded in the canonical receipt.

### Account 2

Namespace: `human:WLJ12lMGKpzErR-WPx_9lfT5GemWb1tQNidWw9Yg-sg`.
History anchor: `0C589500F08054998776842C1EF01A3E086FF0A9199FDEE0049003200CA24930`.
Human U: `me`; personal A: `personal`; S0: `<<"01M603MHKJGFC1NK5C3TMNVAZN">>`.
Explicit selected storage: `ontology_ref(human:WLJ12lMGKpzErR-WPx_9lfT5GemWb1tQNidWw9Yg-sg, 0C589500F08054998776842C1EF01A3E086FF0A9199FDEE0049003200CA24930)`.
Human public key: `AE818083E70C356FCB908E3108B75E7BD2CF66DDEA16BE07F5539B39CDFC4E79`.
Personal-agent public key: `8127951F71F694505D268BAF68088E3C9D7A6F0C40FFB009163376F3258FE9C2`.

The original setup operation names this exact U. Its immutable custody signature verifies against the enrolled executor for this exact A, none/0 prior assignment, destination and key. U and A keys differ. S0 is U-owned and parentless; its local space class belongs to this storage identity. The shared S anchor and pinned source hash are recorded in the canonical receipt.

## Ordered composition and source hashes

The production recipe founds root, then node and its enrollment, then agent, GUI, controllers, space and user. These per-owner lists preserve the source composition order. Node-instance source is frozen in the node foundation’s template; private components are frozen in the user foundation.

- root: `quod_root.pl`.
- node: `quod_node.pl`.
- agent: `quod_agent.pl`.
- gui: `quod_gui.pl`, `gui_measure.pl`, `gui_scene.pl`, `gui_tools.pl`.
- controllers: `quod_controllers.pl`.
- space: `quod_space.pl`.
- user: `quod_user.pl`.
- private_account: `user_instance.pl`, `agent_instance.pl`, `quod_space.pl`, `gui_instance.pl`.

| Source file | SHA-256 |
| --- | --- |
| agent_instance.pl | `FFEC2E02CFD6BF89E1BC1D26B61CFC6B6FFC9C0FEEA4807C64849E8B45373613` |
| common_predicates.pl | `4174DBC885A04684C60E53D029402AA42BCB1FCBE3B1F0EE6A07AE83607CEBEC` |
| gui_instance.pl | `A90EA880F2B55DA703E11CE860771EF97734AF3BF419D562BA32969A2F1BE56A` |
| gui_measure.pl | `95B1C373B7E4E6C227D5106357B4696BB9CA7E102F630D58A869D7854FCE5B58` |
| gui_scene.pl | `BEE340E81BA7320498F611F2C8CBA0158857333E3F2F42E1E4AC72DB8EF4C7FD` |
| gui_tools.pl | `75CE5FD72A19FC74223E1158A2A02A1034C4751B7A97F7C970937DC1C6ADC3BF` |
| node_instance.pl | `B54DE016F5F413FD6A5E3118AC25B824BF4FFD3133E419924250E87678989C40` |
| quod_agent.pl | `58664252AF00FF0137D88268A529475941641ED34A7C199E68A1C5DABC49BB5F` |
| quod_controllers.pl | `78DF5F091B5995D17A7465EBB416E9472BA1CA39914E66EA2DF849EA357000B2` |
| quod_gui.pl | `969B6AB3EAFD67CF5FD6F36C50B1657C90B34FA134D61657D1DA50EC16863339` |
| quod_node.pl | `F7531DE9C3081EC26F77D43F34A937D2C7CFC2941EF4D27F6858764AE0D900A2` |
| quod_root.pl | `20193024399F1FBCCB745D4E730A2DD52AE6206A5C708815E44415DD8104293A` |
| quod_space.pl | `423AC18BC173B90CDAB1C46BF91EADAC576AE3CC6BED3F101457208B5ED43747` |
| quod_user.pl | `5DD72D559C73F22050372D7659DC278805C05DEA2FBA7DD3BB397FC40AC25258` |
| user_instance.pl | `BE2A2DC06B8E9E533D0EA6EBFC9CD72F17EA623D4382249C37E9576D6D00D6F2` |

Generic common/construction/material policy remains single-owned. Its source hashes are:

- `common_predicates.pl`: `4174dbc885a04684c60e53d029402aa42bcb1fcbe3b1f0ee6a07ae83607cebec`.
- `construction.pl`: `b86de51186ca0a308485d37f11237d26c96439a62681d449d18954c19597a266`.
- `material_policy.pl`: `8cd184e65422e19829ed9f2faade33606c1021f0ce082e3787e5ff636db3123d`.

## Compiled predicate profiles

All eleven profiles and module hashes are in the canonical receipt. The [compiled manifest](inputs/gates-04-compiled-manifest.json) relates them to actual test beams and separately records production release beams, runtime/common sources, locks, generated parser sources and derived Rebar metadata.

| History | Declared compiled modules |
| --- | --- |
| human:WLJ12lMGKpzErR-WPx_9lfT5GemWb1tQNidWw9Yg-sg | quod_agent_predicates |
| human:ltQ_KKCP5MPXLYqsQHy2XuRU0QOOmQsb5-C5DebelbE | quod_agent_predicates |
| m1a:unrelated-agent | quod_agent_predicates |
| node:d179d3873609ecb6aee35315fedbb8743a2130b66fa35d44abbd8ed6812189e3 | quod_ontology_predicates |
| quod:agent | quod_agent_predicates |
| quod:controllers | quod_agent_predicates |
| quod:gui | quod_agent_predicates, quod_gui_predicates |
| quod:node | quod_agent_predicates |
| quod:root | quod_directory_predicates, quod_ontology_predicates |
| quod:space | quod_agent_predicates |
| quod:user | quod_agent_predicates |

No private seed, unlock bytes or raw credential is part of this receipt. These public disposable identities are recorded for verification. M1b Godot interaction, later S0 admission/entry policy and M2/M3 delivery remain open.
