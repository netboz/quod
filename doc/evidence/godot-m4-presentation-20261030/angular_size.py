"""Reference-plane angular measurements, not measured glyphs or headset comfort."""
import json,math
from pathlib import Path
pixels=(1850,496);font=16;distance=2.0;height=1.0
angle=lambda size:math.degrees(2*math.atan(size/(2*distance)))
rows=[]
for name,width in [('retained-before',1.5),('aspect-preserved',height*pixels[0]/pixels[1])]:
    rows.append({'case':name,'panel_metres':[width,height],'metres_per_texture_pixel':[width/pixels[0],height/pixels[1]],'nominal_16px_em_degrees':[angle(font*width/pixels[0]),angle(font*height/pixels[1])],'whole_panel_degrees':[angle(width),angle(height)]})
result={'reference_distance_metres':distance,'actual_case07_texture_pixels':pixels,'representative_font_pixels':font,'method':'2 atan(size/(2 distance)), radians converted to degrees; nominal font em, not measured glyph cap height','unchanged':'panel height, initial world placement and ordinary GUI tree','limit':'The wider panel preserves density and avoids distortion; it does not prove comfortable reach, visible whole-panel coverage or that the reported physical distance issue is resolved. No native projection or pixel-return claim.','rows':rows}
path=Path(__file__).resolve().parent/'inputs/angular-size.json';assert not path.exists();path.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
