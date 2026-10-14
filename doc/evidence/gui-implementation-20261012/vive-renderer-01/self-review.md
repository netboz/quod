# Independent renderer review

Actual Vive entry exposed an unregistered Scene helper. The shared world now
uses Babylon WebXRDefaultExperience.CreateAsync directly, with the existing
.babylon loader registered for controller models. The constructor change began
in vive-gui-03; this packet baseline already contains it.

The world uses right-handed coordinates. Its panel and radial menu applied a
left-handed facing correction, reversing the text. The panel now selects its
direction from the scene convention; the right-handed world menu faces the
viewer directly. No domain/proof/transaction behavior changed.

Client gate01:172/0, true exit0. Build gate01:exit0. Source hashes unchanged.
Actual MCP browser fixture: old obligations pass; rightHandedMenu,
rightHandedPanel and controllerLoader true, browserErrors empty. The fixture
retains left-handed coverage and real pointer/keyboard interactions. Hardware
controller interaction is not established by these checks.

Production delta from this packet baseline: net2 lines (panel net1, loader net1;
menu replacement neutral). Earlier constructor replacement is neutral.
Temporary head-following experiment stays outside production. It exposed a
heading singularity near vertical gaze and repeated native tracking loss;
quaternion heading and holding placement while tracking is lost did not pass
the human stability check. Preserve those failures and verify tracking before
claiming headset comfort.
