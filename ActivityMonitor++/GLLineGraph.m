//
//  GLLineGraph.m
//  ActivityMonitor++
//
//  Created by st on 09/05/2013.
//  Copyright (c) 2013 st. All rights reserved.
//

#import <OpenGLES/EAGLDrawable.h>
#import "AMLog.h"
#import "AMUtils.h"
#import "AMGLBlurEffect.h"
#import "CPULoad.h"
#import "DataLine.h"
#import "GLCommon.h"
#import "GLLineGraph.h"

@interface GLLineGraph() <GLKViewDelegate>
@property (assign, nonatomic) BOOL          initialized;

@property (assign, nonatomic) NSUInteger    dataLineCount;
@property (assign, nonatomic) float         fromValue;
@property (assign, nonatomic) float         toValue;
@property (strong, nonatomic) NSArray       *legendStrings; // NSString* array

@property (strong, nonatomic) GLKView       *glView;

/* Data line */
@property (strong, nonatomic) NSArray       *dataLines;
@property (strong, nonatomic) NSArray       *queuedDataLineData;
@property (assign, nonatomic) GLuint        blurFbo;
@property (assign, nonatomic) GLuint        blurTexture;
@property (assign, nonatomic) GLuint        glVertexArrayBlur;
@property (assign, nonatomic) GLuint        glBufferBlur;
@property (strong, nonatomic) AMGLBlurEffect *blurEffect;

/* Reference lines */
@property (assign, nonatomic) GLuint        glVertexArrayReferenceLine;
@property (assign, nonatomic) GLuint        glBufferReferenceLine;

/* Legends */
@property (assign, nonatomic) GLuint        glVertexArrayLegends;
@property (assign, nonatomic) GLuint        glBufferLegends;
@property (strong, nonatomic) GLKTextureInfo *legendsTexture;

- (void)lateInit;

- (void)setupGL;
- (void)setupVBOs;
- (void)tearDownGL;

- (void)renderDataCurve;
- (void)renderDataCurveToTexture;
- (void)renderDataCurveTexture;
- (void)renderReferenceLines;
- (void)renderLegends;

- (UIImage*)imageWithText:(NSString*)text font:(UIFont*)font color:(UIColor*)color;
@end

@implementation GLLineGraph
@synthesize delegate;
@synthesize effect;
@synthesize aspectRatio;
@synthesize graphBottom;
@synthesize graphTop;
@synthesize graphRight;
@synthesize graphLeft;

@synthesize initialized;

@synthesize dataLineCount=_dataLineCount;
@synthesize fromValue=_fromValue;
@synthesize toValue=_toValue;
@synthesize legendStrings=_legendStrings;

@synthesize glView=_glView;

@synthesize dataLines=_dataLines;
@synthesize queuedDataLineData=_queuedDataLineData;
@synthesize blurFbo=_blurFbo;
@synthesize blurTexture=_blurTexture;
@synthesize glVertexArrayBlur=_glVertexArrayBlur;
@synthesize glBufferBlur=_glBufferBlur;
@synthesize blurEffect=_blurEffect;

@synthesize glVertexArrayReferenceLine=_glVertexArrayReferenceLine;
@synthesize glBufferReferenceLine=_glBufferReferenceLine;
@synthesize legendsTexture=_legendsTexture;

@synthesize glVertexArrayLegends=_glVertexArrayLegends;
@synthesize glBufferLegends=_glBufferLegends;

static const GLfloat kProjectionLeft        = -10.0f;
static const GLfloat kProjectionRight       =  10.0f;
static const GLfloat kProjectionBottom      = -5.0f;
static const GLfloat kProjectionTop         =  5.0f;
static const GLfloat kProjectionNear        =  1.0f;
static const GLfloat kProjectionFar         =  10.0f;

static const GLfloat kGraphGapPercentLeft   = 5;
static const GLfloat kGraphGapPercentTop    = 10;
static const GLfloat kGraphGapPercentRight  = 5;
static const GLfloat kGraphGapPercentBottom = 20;

static const VertexData_t referenceLineData[] = {
    {{ 0.0f, 0.0f, 0.0f }},
    {{ 1.0f, 0.0f, 0.0f }}
};

static const VertexData_t legendData[] = {
    {{ 0.0f, 0.0f, 0.0f }, { 0.0f, 0.0f }},
    {{ 1.0f, 0.0f, 0.0f }, { 1.0f, 0.0f }},
    {{ 0.0f, 1.0f, 0.0f }, { 0.0f, 1.0f }},
    {{ 1.0f, 0.0f, 0.0f }, { 1.0f, 0.0f }},
    {{ 1.0f, 1.0f, 0.0f }, { 1.0f, 1.0f }},
    {{ 0.0f, 1.0f, 0.0f }, { 0.0f, 1.0f }}
};

static VertexData_t dataBlur[] = {
    {{ 0.0f, 0.0f, kModelZ }, { 0.0f, 0.0f }},
    {{ 1.0f, 0.0f, kModelZ }, { 1.0f, 0.0f }},
    {{ 0.0f, 1.0f, kModelZ }, { 0.0f, 1.0f }},
    {{ 1.0f, 0.0f, kModelZ }, { 1.0f, 0.0f }},
    {{ 1.0f, 1.0f, kModelZ }, { 1.0f, 1.0f }},
    {{ 0.0f, 1.0f, kModelZ }, { 0.0f, 1.0f }}
};

#pragma mark - public

- (id)initWithGLKView:(GLKView*)aGLView
        dataLineCount:(NSUInteger)count
            fromValue:(float)from
              toValue:(float)to
              legends:(NSArray*)legends
             delegate:(id)aDelegate
{
    if (self = [super init])
    {
        self.delegate = aDelegate;
        
        self.dataLineCount = count;
        self.fromValue = from;
        self.toValue = to;
        self.legendStrings = legends;
                
        self.glView = aGLView;
        self.view = self.glView;
                                
        self.graphTop = [AMUtils percentageValueFromMax:kProjectionTop min:kProjectionBottom percent:100-kGraphGapPercentTop];
        self.graphBottom = [AMUtils percentageValueFromMax:kProjectionTop min:kProjectionBottom percent:kGraphGapPercentBottom];
        self.graphLeft = [AMUtils percentageValueFromMax:kProjectionRight min:kProjectionLeft percent:kGraphGapPercentLeft];
        self.graphRight = [AMUtils percentageValueFromMax:kProjectionRight min:kProjectionLeft percent:100-kGraphGapPercentRight];
        
        [self setupGL];
    }
    return self;
}

- (void)dealloc
{
    [self tearDownGL];
}

- (void)addDataValue:(NSArray*)data
{
    for (NSUInteger i = 0; i < data.count; ++i)
    {
        NSNumber *number = [data objectAtIndex:i];
        GLfloat value = [number floatValue];
        DataLine *dataLine = [self.dataLines objectAtIndex:i];
        [dataLine addLineDataValue:value];
    }
}

- (void)resetDataArray:(NSArray*)dataArray
{
    if (self.dataLines)
    {
        for (DataLine *line in self.dataLines)
        {
            [line resetLineData];
        }
        
        for (NSUInteger i = 0; i < dataArray.count; ++i)
        {
            NSArray *data = [dataArray objectAtIndex:i];
            [self addDataValue:data];
        }
    }
    else
    {
        self.queuedDataLineData = [NSArray arrayWithArray:dataArray];
    }
}

#pragma mark - private

- (void)lateInit
{
    if (self.initialized)
    {
        return;
    }
    
    assert(self.glView.bounds.size.width > 0);
    assert(self.glView.bounds.size.height > 0);
    
    self.initialized = YES;
    
    GLfloat drawableWidth = self.glView.contentScaleFactor * self.glView.bounds.size.width;
    GLfloat drawableHeight = self.glView.contentScaleFactor * self.glView.bounds.size.height;
    self.aspectRatio = fabsf(drawableWidth / drawableHeight);
    
    self.effect.transform.projectionMatrix = GLKMatrix4MakeOrtho(kProjectionLeft * self.aspectRatio,
                                                                 kProjectionRight * self.aspectRatio,
                                                                 kProjectionBottom,
                                                                 kProjectionTop,
                                                                 kProjectionNear,
                                                                 kProjectionFar);
    
    NSArray *lineColors = [NSArray arrayWithObjects:[UIColor colorWithRed:1.0f green:1.0f blue:0.0f alpha:1.0f],
                                                    [UIColor colorWithRed:127.0f/255.0f green:149.0f/255.0f blue:183.0f/255.0f alpha:1.0f],
                                                    nil];
    NSMutableArray *lines = [[NSMutableArray alloc] initWithCapacity:self.dataLineCount];
    for (NSUInteger i = 0; i < self.dataLineCount; ++i)
    {
        DataLine *dataLine = [[DataLine alloc] initWithColor:[lineColors objectAtIndex:i] forGraph:self];
        [lines addObject:dataLine];
    }
    self.dataLines = [[NSArray alloc] initWithArray:lines];
    
    if (self.queuedDataLineData)
    {
        [self resetDataArray:self.queuedDataLineData];
        self.queuedDataLineData = nil;
    }
    
    /* Data line blur framebuffer */
    glGenFramebuffers(1, &_blurFbo);
    glBindFramebuffer(GL_FRAMEBUFFER, self.blurFbo);

    glGenTextures(1, &_blurTexture);
    glBindTexture(GL_TEXTURE_2D, self.blurTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, drawableWidth, drawableHeight,
                 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, self.blurTexture, 0);
    
    GLuint status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE)
    {
        AMWarn(@"%s: blur framebuffer init has failed: 0x%X", __PRETTY_FUNCTION__, status);
    }
    
    [self.glView bindDrawable];
    
    GL_CHECK_ERROR();
    
    [self.delegate graphFinishedInitializing];
}

- (void)setupGL
{
    EAGLContext *glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!glContext)
    {
        AMWarn(@"%s: EAGLContext == nil", __PRETTY_FUNCTION__);
        return;
    }
    
    [self.glView setContext:glContext];
    [EAGLContext setCurrentContext:self.glView.context];
    
    self.glView.drawableMultisample = GLKViewDrawableMultisample4X;
    
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    // Enable for performance reasons as it removes many of the triangles to draw.
    glEnable(GL_CULL_FACE);
    // Enabled by default.
    glDisable(GL_DITHER);
    
    self.effect = [[GLKBaseEffect alloc] init];
    self.effect.transform.modelviewMatrix = GLKMatrix4MakeTranslation(0.0f, 0.0f, -5.0f);
    
    /* Textures */
    UIImage *img = [self imageWithText:@"Test" font:[UIFont fontWithName:@"Helvetica" size:84.0f] color:[UIColor redColor]];
    self.legendsTexture = [GLKTextureLoader textureWithCGImage:img.CGImage options:nil error:NULL];
    self.effect.texture2d0.name = self.legendsTexture.name;
    self.effect.texture2d0.target = self.legendsTexture.target;
    
    self.blurEffect = [[AMGLBlurEffect alloc] init];
    
    [self setupVBOs];
}

- (void)setupVBOs
{
    /* VBO */
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindVertexArrayOES(0);
    
    /*
     * Blur VBO.
     */
    {
        glGenVertexArraysOES(1, &_glVertexArrayBlur);
        glBindVertexArrayOES(self.glVertexArrayBlur);
        
        glGenBuffers(1, &_glBufferBlur);
        glBindBuffer(GL_ARRAY_BUFFER, self.glBufferBlur);
        glBufferData(GL_ARRAY_BUFFER, sizeof(dataBlur), dataBlur, GL_STATIC_DRAW);
        
        glVertexAttribPointer(GLKVertexAttribPosition, 3, GL_FLOAT, GL_FALSE, sizeof(VertexData_t),
                              NULL + offsetof(VertexData_t, positionCoords));
        glEnableVertexAttribArray(GLKVertexAttribPosition);
        
        glVertexAttribPointer(GLKVertexAttribTexCoord0, 2, GL_FLOAT, GL_FALSE, sizeof(VertexData_t),
                              NULL + offsetof(VertexData_t, textureCoords));
        glEnableVertexAttribArray(GLKVertexAttribTexCoord0);
    }
    
    /*
     * Reference lines VBO.
     */
    {
        glGenVertexArraysOES(1, &_glVertexArrayReferenceLine);
        glBindVertexArrayOES(self.glVertexArrayReferenceLine);
        
        glGenBuffers(1, &_glBufferReferenceLine);
        glBindBuffer(GL_ARRAY_BUFFER, self.glBufferReferenceLine);
        glBufferData(GL_ARRAY_BUFFER, sizeof(referenceLineData), referenceLineData, GL_STATIC_DRAW);
        
        glVertexAttribPointer(GLKVertexAttribPosition, 3, GL_FLOAT, GL_FALSE, sizeof(VertexData_t),
                              NULL + offsetof(VertexData_t, positionCoords));
        glEnableVertexAttribArray(GLKVertexAttribPosition);
        
        GL_CHECK_ERROR();
    }
    
    /*
     * Legend lines VBO.
     */
    {
        glGenVertexArraysOES(1, &_glVertexArrayLegends);
        glBindVertexArrayOES(self.glVertexArrayLegends);
        
        glGenBuffers(1, &_glBufferLegends);
        glBindBuffer(GL_ARRAY_BUFFER, self.glBufferLegends);
        glBufferData(GL_ARRAY_BUFFER, sizeof(legendData), legendData, GL_STATIC_DRAW);
        
        glVertexAttribPointer(GLKVertexAttribPosition, 3, GL_FLOAT, GL_FALSE,
                              sizeof(VertexData_t), NULL + offsetof(VertexData_t, positionCoords));
        glEnableVertexAttribArray(GLKVertexAttribPosition);
        
        glVertexAttribPointer(GLKVertexAttribTexCoord0, 2, GL_FLOAT, GL_FALSE,
                              sizeof(VertexData_t), NULL + offsetof(VertexData_t, textureCoords));
        glEnableVertexAttribArray(GLKVertexAttribTexCoord0);
        
        
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        
        GL_CHECK_ERROR();
    }
}

- (void)tearDownGL
{
    glDeleteBuffers(1, &_glBufferReferenceLine);
    glDeleteVertexArraysOES(1, &_glVertexArrayReferenceLine);
    glDeleteBuffers(1, &_glBufferLegends);
    glDeleteVertexArraysOES(1, &_glVertexArrayLegends);
    self.effect = nil;
    
    GL_CHECK_ERROR();
}

- (void)renderDataCurve
{    
    [self renderDataCurveToTexture];
    [self renderDataCurveTexture];
}

- (void)renderDataCurveToTexture
{
    glBindFramebuffer(GL_FRAMEBUFFER, self.blurFbo);
    glViewport(0, 0, self.glView.drawableWidth, self.glView.drawableHeight);
    
    glClearColor(1.0f, 1.0f, 1.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    for (DataLine *line in self.dataLines)
    {
        [line render];
    }
    
    [self.glView bindDrawable];
}

- (void)renderDataCurveTexture
{
    // Render the texture back to the screen.
    
    GLfloat x = kProjectionLeft * self.aspectRatio;
    GLfloat y = kProjectionBottom;
    GLfloat xScale = (kProjectionRight - kProjectionLeft) * self.aspectRatio;
    GLfloat yScale = kProjectionTop - kProjectionBottom;
    
    glBindVertexArrayOES(self.glVertexArrayBlur);
    
    GLKVector3 position = GLKVector3Make(x, y, kModelZ);
    GLKVector3 rotation = GLKVector3Make(0.0f, 0.0f, 0.0f);
    GLKMatrix4 scale = GLKMatrix4MakeScale(xScale, yScale, 1.0f);
    GLKMatrix4 modelMatrix = [GLCommon modelMatrixWithPosition:position rotation:rotation scale:scale];
    GLKMatrix4 mvpMatrix = GLKMatrix4Multiply(self.effect.transform.projectionMatrix, modelMatrix);
    
    self.blurEffect.mvpMatrix = mvpMatrix;
    self.blurEffect.texture0 = self.blurTexture;
    [self.blurEffect prepareToDraw];
    glDrawArrays(GL_TRIANGLES, 0, sizeof(dataBlur) / sizeof(VertexData_t));

    GL_CHECK_ERROR();
}

- (void)renderReferenceLines
{
    GLfloat x = self.graphLeft * self.aspectRatio;
    GLfloat xScale = (self.graphRight - self.graphLeft) * self.aspectRatio;
    GLfloat yScale = self.graphTop - self.graphBottom;
    
    /*
     * Top line.
     */
    {
        glBindVertexArrayOES(self.glVertexArrayReferenceLine);
        
        GLKVector3 position = GLKVector3Make(x, self.graphTop, kModelZ);
        GLKVector3 rotation = GLKVector3Make(0.0f, 0.0f, 0.0f);
        GLKMatrix4 scale = GLKMatrix4MakeScale(xScale, 1.0f, 1.0f);
        GLKMatrix4 modelMatrix = [GLCommon modelMatrixWithPosition:position rotation:rotation scale:scale];
        
        self.effect.transform.modelviewMatrix = modelMatrix;
        self.effect.useConstantColor = YES;
        self.effect.constantColor = GLKVector4Make(0.25f, 0.25f, 0.25f, 1.0f);
        self.effect.texture2d0.enabled = NO;
        [self.effect prepareToDraw];
        
        glLineWidth(1.0f);
        glDrawArrays(GL_LINES, 0, sizeof(referenceLineData) / sizeof(VertexData_t));
        
        GL_CHECK_ERROR();
    }
    
    /*
     * Mid line.
     */
    {
        /*
        GLfloat y = [AMUtils percentageValueFromMax:self.graphTop min:self.graphBottom percent:50];
        
        glBindVertexArrayOES(self.glVertexArrayReferenceLine);
        
        GLKVector3 position = GLKVector3Make(x, y, kModelZ);
        GLKVector3 rotation = GLKVector3Make(0.0f, 0.0f, 0.0f);
        GLKMatrix4 scale = GLKMatrix4MakeScale(xScale, 1.0f, 1.0f);
        GLKMatrix4 modelMatrix = [GLCommon modelMatrixWithPosition:position rotation:rotation scale:scale];
        
        self.effect.transform.modelviewMatrix = modelMatrix;
        self.effect.useConstantColor = YES;
        self.effect.constantColor = GLKVector4Make(0.25f, 0.25f, 0.25f, 1.0f);
        self.effect.texture2d0.enabled = NO;
        [self.effect prepareToDraw];
        
        glLineWidth(1.0f);
        glDrawArrays(GL_LINES, 0, sizeof(referenceLineData) / sizeof(VertexData_t));
        */
        GL_CHECK_ERROR();
    }
    
    /*
     * Bottom line.
     */
    {
        glBindVertexArrayOES(self.glVertexArrayReferenceLine);
        
        GLKVector3 position = GLKVector3Make(x, self.graphBottom, kModelZ);
        GLKVector3 rotation = GLKVector3Make(0.0f, 0.0f, 0.0f);
        GLKMatrix4 scale = GLKMatrix4MakeScale(xScale, 1.0f, 1.0f);
        GLKMatrix4 modelMatrix = [GLCommon modelMatrixWithPosition:position rotation:rotation scale:scale];
        
        self.effect.transform.modelviewMatrix = modelMatrix;
        self.effect.useConstantColor = YES;
        self.effect.constantColor = GLKVector4Make(0.25f, 0.25f, 0.25f, 1.0f);
        self.effect.texture2d0.enabled = NO;
        [self.effect prepareToDraw];
        
        glLineWidth(1.0f);
        glDrawArrays(GL_LINES, 0, sizeof(referenceLineData) / sizeof(VertexData_t));
        
        GL_CHECK_ERROR();
    }
    
    /*
     * Right line.
     */
    {
        glBindVertexArrayOES(self.glVertexArrayReferenceLine);
        
        GLfloat xVertical = self.graphRight * self.aspectRatio;
        GLKVector3 position = GLKVector3Make(xVertical, self.graphBottom, kModelZ);
        GLKVector3 rotation = GLKVector3Make(0.0f, 0.0f, GLKMathDegreesToRadians(90.0f));
        GLKMatrix4 scale = GLKMatrix4MakeScale(1.0f, yScale, 1.0f);
        GLKMatrix4 modelMatrix = [GLCommon modelMatrixWithPosition:position rotation:rotation scale:scale];

        self.effect.transform.modelviewMatrix = modelMatrix;
        self.effect.useConstantColor = YES;
        self.effect.constantColor = GLKVector4Make(0.2f, 0.2f, 0.2f, 1.0f);
        self.effect.texture2d0.enabled = NO;
        [self.effect prepareToDraw];
        
        glLineWidth(1.0f);
        glDrawArrays(GL_LINES, 0, sizeof(referenceLineData) / sizeof(VertexData_t));
        
        GL_CHECK_ERROR();
    }
    
    /*
     * Left line.
     */
    {
        glBindVertexArrayOES(self.glVertexArrayReferenceLine);
        
        GLfloat xVertical = self.graphLeft * self.aspectRatio;
        GLKVector3 position = GLKVector3Make(xVertical, self.graphBottom, kModelZ);
        GLKVector3 rotation = GLKVector3Make(0.0f, 0.0f, GLKMathDegreesToRadians(90.0f));
        GLKMatrix4 scale = GLKMatrix4MakeScale(1.0f, yScale, 1.0f);
        GLKMatrix4 modelMatrix = [GLCommon modelMatrixWithPosition:position rotation:rotation scale:scale];
        
        self.effect.transform.modelviewMatrix = modelMatrix;
        self.effect.useConstantColor = YES;
        self.effect.constantColor = GLKVector4Make(0.2f, 0.2f, 0.2f, 1.0f);
        self.effect.texture2d0.enabled = NO;
        [self.effect prepareToDraw];
        
        glLineWidth(1.0f);
        glDrawArrays(GL_LINES, 0, sizeof(referenceLineData) / sizeof(VertexData_t));
        
        GL_CHECK_ERROR();
    }
}

- (void)renderLegends
{
    GLfloat aspect = fabsf((GLfloat)self.legendsTexture.width / (GLfloat)self.legendsTexture.height);
    GLfloat xScale = self.legendsTexture.width / 60.0f * aspect;
    GLfloat yScale = self.legendsTexture.height / 60.0f;
    
    glBindVertexArrayOES(self.glVertexArrayLegends);
    
    GLKVector3 position = GLKVector3Make(0.0f, self.graphBottom, kModelZ);
    GLKVector3 rotation = GLKVector3Make(0.0f, 0.0f, 0.0f);
    GLKMatrix4 scale = GLKMatrix4MakeScale(xScale, yScale, 1.0f);
    GLKMatrix4 modelMatrix = [GLCommon modelMatrixWithPosition:position rotation:rotation scale:scale];
    
    self.effect.transform.modelviewMatrix = modelMatrix;
    self.effect.useConstantColor = GL_FALSE;
    self.effect.texture2d0.enabled = GL_TRUE;
    self.effect.texture2d0.name = self.legendsTexture.name;
    self.effect.texture2d0.target = self.legendsTexture.target;
    self.effect.texture2d0.envMode = GLKTextureEnvModeReplace;
    [self.effect prepareToDraw];

    glDrawArrays(GL_TRIANGLES, 0, sizeof(legendData) / sizeof(VertexData_t));
    
    GL_CHECK_ERROR();
}

- (UIImage*)imageWithText:(NSString*)text font:(UIFont*)font color:(UIColor*)color
{
    UIImage *texture;
    CGSize textureSize = [text sizeWithFont:font];
    
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef imageContext = CGBitmapContextCreate(NULL, textureSize.width, textureSize.height, 8,
                                                      textureSize.width * 4, // 4 elements per pixel (RGBA)
                                                      rgbColorSpace,
                                                      kCGBitmapByteOrderDefault|kCGImageAlphaPremultipliedFirst);
    UIGraphicsPushContext(imageContext);
    
    CGContextSetFillColorWithColor(imageContext, color.CGColor);
    [text drawAtPoint:CGPointMake(0.0f, 0.0f) withFont:font];
    CGImageRef cgTexture = CGBitmapContextCreateImage(imageContext);
    texture = [UIImage imageWithCGImage:cgTexture];
    
    UIGraphicsPopContext();
    CGImageRelease(cgTexture);
    CGContextRelease(imageContext);
    CGColorSpaceRelease(rgbColorSpace);    
    
    return texture;
}

#pragma mark - private override

- (void)viewDidLayoutSubviews
{
    [self lateInit];
}

-(void)update
{
}

#pragma mark - GLKView delegate

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
    //glBlendEquation(GL_MAX_EXT);
    
    glViewport(0, 0, self.glView.drawableWidth, self.glView.drawableHeight);

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    
    [self renderReferenceLines];
    [self renderLegends];
    [self renderDataCurve];
}

@end
