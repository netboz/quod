Quod roof cutout for ComfyUI

This is an importable workflow, not a Python custom node. It uses built-in
LoadImage, JoinImageWithAlpha, MaskToImage, PreviewImage and SaveImage nodes.
No model downloads or custom-node installation are required.

SETUP
1. Drag roof-cutout.json onto the ComfyUI canvas (or use Workflow > Open).
2. In Load Image, upload the included roof-source.png. Alternatively, copy it
   into your ComfyUI input directory before loading the workflow.
3. Right-click Load Image and choose Open in Mask Editor.

SELECT THE ROOF
Use the MASK layer / Mask Pen, not the RGB Paint Pen.
Paint everything you want removed. Use a large brush for open regions and
zoom in with a smaller brush along the roof boundary.

Remove:
- sky above the roof and landscape below its large arch;
- scenery inside the small left and right openings;
- the entire foreground floor, including the raised basin edges, miniature
  landscape and the bottom-right text.

Keep:
- the peach canopy and its cream outer rim;
- the side supports, ending where they meet the floor;
- the architectural rims around the small openings.

The support/floor boundary is an artistic choice where the surfaces blend.
Do not cut away the supports just to make a horizontal crop. Keep small
openings empty and avoid leaving floating flecks around the roof.

EXPORT
Save the mask back to Load Image, then click Run / Queue Prompt.
The mask preview must show WHITE where pixels are removed and BLACK where
the roof remains. Grey mask pixels produce partial transparency.
The workflow deliberately has no Invert Mask node: JoinImageWithAlpha
internally turns ComfyUI's removal mask into the PNG opacity channel.
The saved image is output/quod/roof_00001_.png (number increments).
Use the Save Image result, not the original image or the mask preview.

Confirm transparency in an image editor using a checkerboard background.
Some previews display transparent pixels against black. Saving before you
paint a mask will keep the whole original image opaque.

HANDOFF TO 3D
Load the exported PNG into your existing image-to-3D workflow. Its input
adapter may expect RGB plus a separate mask or a specific background;
follow that workflow's convention. This cutout workflow exports RGBA only.
Keep this workflow separate from your 3D graph until the cutout looks right.

LIMITATIONS
This is manual, lossless selection of visible source pixels, not automatic
semantic segmentation. It does not complete the cropped left/right edges,
expose the hidden upper surface or generate new camera angles. The 3D model
will still infer missing geometry. It does not guarantee a usable 3D mesh.

VERIFICATION
Graph connections and mask semantics were checked against ComfyUI's built-in
node source. This workflow has not been executed in a ComfyUI installation.

References:
https://docs.comfy.org/interface/maskeditor
https://docs.comfy.org/built-in-nodes/JoinImageWithAlpha
https://github.com/comfyanonymous/ComfyUI/blob/master/comfy_extras/nodes_compositing.py
