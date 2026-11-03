#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const JSBSimErrorDomain;

typedef NS_ERROR_ENUM(JSBSimErrorDomain, JSBSimErrorCode) {
    JSBSimErrorModelLoad = 1,
    JSBSimErrorUnknownProperty = 2,
    JSBSimErrorInitialConditions = 3,
    JSBSimErrorTrim = 4,
    JSBSimErrorStep = 5,
};

/// JSBSim trim modes (see FGTrim.h). Ground trim settles the aircraft on its gear.
typedef NS_ENUM(NSInteger, JSBSimTrimMode) {
    JSBSimTrimModeLongitudinal = 0,
    JSBSimTrimModeFull = 1,
    JSBSimTrimModeGround = 2,
};

/// Thin Objective-C++ wrapper around one JSBSim FGFDMExec instance.
/// Every JSBSim C++ exception is converted to an NSError; nothing is swallowed.
@interface JSBSimAircraft : NSObject

/// Loads `model` from `<root>/aircraft/<model>/<model>.xml`, with engines in `<root>/engine`.
- (nullable instancetype)initWithRootDirectory:(NSString *)rootDirectory
                                         model:(NSString *)model
                                      timeStep:(double)timeStep
                                         error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) double timeStep;

/// Resolves a JSBSim property once. Use the returned handle for fast per-frame access.
- (nullable NSNumber *)handleForProperty:(NSString *)name error:(NSError **)error;
- (double)valueForHandle:(NSInteger)handle;
- (void)setValue:(double)value forHandle:(NSInteger)handle;

/// Places the aircraft and re-initialises every JSBSim model.
- (BOOL)resetToLatitude:(double)latitudeDegrees
              longitude:(double)longitudeDegrees
       terrainElevation:(double)terrainElevationFeet
            altitudeAGL:(double)altitudeAGLFeet
                heading:(double)headingDegrees
     calibratedAirspeed:(double)airspeedKnots
        flightPathAngle:(double)flightPathAngleDegrees
                  error:(NSError **)error;

/// Runs JSBSim's trim routine so the aircraft starts in steady flight or settled on the ground.
- (BOOL)trimWithMode:(JSBSimTrimMode)mode error:(NSError **)error;

/// Advances the simulation by `steps` fixed time steps.
- (BOOL)runSteps:(NSInteger)steps error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
