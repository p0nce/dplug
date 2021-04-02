/**
A PBR knob with texture.

Copyright: Guillaume Piolat 2019.
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module dplug.pbrwidgets.imageknob;

import std.math;

import dplug.math.vector;
import dplug.math.box;

import dplug.core.nogc;
import dplug.gui.context;
import dplug.pbrwidgets.knob;
import dplug.graphics.mipmap;
import dplug.client.params;
import dplug.graphics.color;
import dplug.graphics.image;
import dplug.graphics.draw;
import dplug.graphics.drawex;

nothrow:
@nogc:


/// Type of image being used for Knob graphics.
/// It used to be a one level deep Mipmap (ie. a flat image with sampling capabilities).
/// It is now a regular `OwnedImage` since it is resized in `reflow()`.
/// Use it an opaque type: its definition can change.
alias KnobImage = OwnedImage!RGBA;

/// Loads a knob image and rearrange channels to be fit to pass to `UIImageKnob`.
///
/// The input format of such an image is an an arrangement of squares:
///
///         h              h           h            h         h
///   +------------+------------+------------+------------+-----------+
///   |            |            |            |            |           |
///   |  alpha     |  basecolor |   depth    |  material  |  emissive |
/// h |  grayscale |     RGB    |  grayscale |    RMS     | grayscale |
///   |  (R used)  |            |(sum of RGB)|            | (R used)  |
///   |            |            |            |            |           |
///   +------------+------------+------------+------------+-----------+
///
///
/// This format is extended so that:
/// - the emissive component is copied into the diffuse channel to form a full RGBA quad,
/// - same for material with the physical channel, which is assumed to be always "full physical"
///
/// Recommended format: PNG, for example a 230x46 24-bit image.
/// Note that such an image is resized before use.
///
/// Warning: the returned `KnobImage` should be destroyed by the caller with `destroyFree`.
/// Note: internal resizing does not preserve aspect ratio exactly for 
///       approximate scaled rectangles.
KnobImage loadKnobImage(in void[] data)
{
    OwnedImage!RGBA image = loadOwnedImage(data);

    // Expected dimension is 5H x H
    assert(image.w == image.h * 5);

    int h = image.h;
    
    for (int y = 0; y < h; ++y)
    {
        RGBA[] line = image.scanline(y);

        RGBA[] basecolor = line[h..2*h];
        RGBA[] material = line[3*h..4*h];
        RGBA[] emissive = line[4*h..5*h];

        for (int x = 0; x < h; ++x)
        {
            // Put emissive red channel into the alpha channel of base color
            basecolor[x].a = emissive[x].r;

            // Fills unused with 255
            material[x].a = 255;
        }
    }
    return image;
}


/// UIKnob which replace the knob part by a rotated PBR image.
class UIImageKnob : UIKnob
{
public:
nothrow:
@nogc:

    /// If `true`, diffuse data is blended in the diffuse map using alpha information.
    /// If `false`, diffuse is left untouched.
    bool drawToDiffuse = true;

    /// If `true`, depth data is blended in the depth map using alpha information.
    /// If `false`, depth is left untouched.
    bool drawToDepth = true;

    /// If `true`, material data is blended in the material map using alpha information.
    /// If `false`, material is left untouched.
    bool drawToMaterial = true;

    /// `knobImage` should have been loaded with `loadKnobImage`.
    /// Warning: `knobImage` must outlive the knob, it is borrowed.
    this(UIContext context, KnobImage knobImage, FloatParameter parameter)
    {
        super(context, parameter);
        _knobImage = knobImage;
        _knobImageResized = mallocNew!(Mipmap!RGBA)();
    }

    ~this()
    {
        _knobImageResized.destroyFree();
    }

    override void reflow()
    {
        int numTiles = 5;

        // _knobImageResized is a 1-level mipmap
        // Note that this is only to benefit from being rotated
        _knobImageResized.size(1, position.width * numTiles, position.height);

        // Limitation: the source _knobImage should be multiple of numTiles pixels.
        assert(_knobImage.w % numTiles == 0);

        auto resizer = context.globalImageResizer;
        ImageRef!RGBA destlevel0 = _knobImageResized.levels[0].toRef;

        int wsource = _knobImage.w / numTiles;
        int wdest   = destlevel0.w / numTiles;

        // Note: in order to avoid slight sample offsets, each subframe needs to be resized separately.
        for (int tile = 0; tile < numTiles; ++tile)
        {
            ImageRef!RGBA source = _knobImage.toRef.cropImageRef(rectangle(wsource * tile, 0, wsource, _knobImage.h       ));
            ImageRef!RGBA dest   = destlevel0.cropImageRef(rectangle(wdest   * tile, 0, wdest, destlevel0.h));
            resizer.resizeImage(source, dest);
        }
    }


    override void drawKnob(ImageRef!RGBA diffuseMap, ImageRef!L16 depthMap, ImageRef!RGBA materialMap, box2i[] dirtyRects)
    {
        float radius = getRadius();
        vec2f center = getCenter();
        float valueAngle = getValueAngle() + PI_2;
        float cosa = cos(valueAngle);
        float sina = sin(valueAngle);

        int w = _knobImageResized.width / 5;
        int h = _knobImageResized.height;

        // Note: slightly incorrect, since our resize in reflow doesn't exactly preserve aspect-ratio
        vec2f rotate(vec2f v) pure nothrow @nogc
        {
            return vec2f(v.x * cosa + v.y * sina, 
                         v.y * cosa - v.x * sina);
        }

        foreach(dirtyRect; dirtyRects)
        {
            ImageRef!RGBA cDiffuse  = diffuseMap.cropImageRef(dirtyRect);
            ImageRef!RGBA cMaterial = materialMap.cropImageRef(dirtyRect);
            ImageRef!L16 cDepth     = depthMap.cropImageRef(dirtyRect);

            // Basically we'll find a coordinate in the knob image for each pixel in the dirtyRect 

            // source center 
            vec2f sourceCenter = vec2f(w*0.5f, h*0.5f);

            for (int y = 0; y < dirtyRect.height; ++y)
            {
                RGBA* outDiffuse = cDiffuse.scanline(y).ptr;
                L16* outDepth = cDepth.scanline(y).ptr;
                RGBA* outMaterial = cMaterial.scanline(y).ptr;

                for (int x = 0; x < dirtyRect.width; ++x)
                {
                    vec2f destPos = vec2f(x + dirtyRect.min.x, y + dirtyRect.min.y);
                    vec2f sourcePos = sourceCenter + rotate(destPos - center);

                    // If the point is outside the knobimage, it is considered to have an alpha of zero
                    float fAlpha = 0.0f;
                    if ( (sourcePos.x >= 0.5f) && (sourcePos.x < (h - 0.5f))
                     &&  (sourcePos.y >=  0.5f) && (sourcePos.y < (h - 0.5f)) )
                    {
                        fAlpha = _knobImageResized.linearSample(0, sourcePos.x, sourcePos.y).r;

                        if (fAlpha > 0)
                        {
                            vec4f fDiffuse = _knobImageResized.linearSample(0, sourcePos.x + h, sourcePos.y); 
                            vec4f fDepth = _knobImageResized.linearSample(0, sourcePos.x + h*2, sourcePos.y); 
                            vec4f fMaterial = _knobImageResized.linearSample(0, sourcePos.x + h*3, sourcePos.y);

                            ubyte alpha = cast(ubyte)(0.5f + fAlpha);
                            ubyte R = cast(ubyte)(0.5f + fDiffuse.r);
                            ubyte G = cast(ubyte)(0.5f + fDiffuse.g);
                            ubyte B = cast(ubyte)(0.5f + fDiffuse.b);
                            ubyte E = cast(ubyte)(0.5f + fDiffuse.a);

                            ubyte Ro = cast(ubyte)(0.5f + fMaterial.r);
                            ubyte M = cast(ubyte)(0.5f + fMaterial.g);
                            ubyte S = cast(ubyte)(0.5f + fMaterial.b);
                            ubyte X = cast(ubyte)(0.5f + fMaterial.a);

                            ushort depth = cast(ushort)(0.5f + 257 * (fDepth.r + fDepth.g + fDepth.b) / 3);

                            RGBA diffuse = RGBA(R, G, B, E);
                            RGBA material = RGBA(Ro, M, S, X);

                            if (drawToDiffuse)
                                outDiffuse[x] = blendColor( diffuse, outDiffuse[x], alpha);
                            if (drawToMaterial)
                                outMaterial[x] = blendColor( material, outMaterial[x], alpha);

                            if (drawToDepth)
                            {
                                int interpolatedDepth = depth * alpha + outDepth[x].l * (255 - alpha);
                                outDepth[x] = L16(cast(ushort)( (interpolatedDepth + 128) / 255));
                            }
                        }
                    }
                }
            }
        }
    }

    KnobImage _knobImage; // borrowed image of the knob
    Mipmap!RGBA _knobImageResized; // owned resized image
}

