#import "JSBSimAircraft.h"

#import <os/log.h>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

// Xcode debug builds define DEBUG=1, which collides with JSBSim's LogLevel::DEBUG enumerator.
#pragma push_macro("DEBUG")
#undef DEBUG
#include "FGFDMExec.h"
#include "initialization/FGInitialCondition.h"
#include "input_output/FGPropertyManager.h"
#include "simgear/misc/sg_path.hxx"
#pragma pop_macro("DEBUG")

NSErrorDomain const JSBSimErrorDomain = @"com.joanlouji.tvflightsim.jsbsim";

static os_log_t JSBSimLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.joanlouji.tvflightsim", "jsbsim"); });
    return log;
}

static NSError *MakeError(JSBSimErrorCode code, NSString *message) {
    os_log_error(JSBSimLog(), "%{public}@", message);
    return [NSError errorWithDomain:JSBSimErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void AssignError(NSError **out, JSBSimErrorCode code, NSString *message) {
    NSError *error = MakeError(code, message);
    if (out) { *out = error; }
}

@implementation JSBSimAircraft {
    std::unique_ptr<JSBSim::FGFDMExec> _fdm;
    std::vector<SGPropertyNode_ptr> _nodes;
}

- (nullable instancetype)initWithRootDirectory:(NSString *)rootDirectory
                                         model:(NSString *)model
                                      timeStep:(double)timeStep
                                         error:(NSError **)error {
    self = [super init];
    if (!self) { return nil; }
    _timeStep = timeStep;

    // JSBSim prints its banner and model summary to stdout unless the debug level is 0.
    setenv("JSBSIM_DEBUG", "0", 1);
    try {
        _fdm = std::make_unique<JSBSim::FGFDMExec>();
        _fdm->SetRootDir(SGPath::fromUtf8(rootDirectory.UTF8String));
        _fdm->SetAircraftPath(SGPath("aircraft"));
        _fdm->SetEnginePath(SGPath("engine"));
        _fdm->SetSystemsPath(SGPath("systems"));
        if (!_fdm->LoadModel(model.UTF8String)) {
            AssignError(error, JSBSimErrorModelLoad,
                        [NSString stringWithFormat:@"JSBSim could not load model '%@' from %@", model, rootDirectory]);
            return nil;
        }
        _fdm->Setdt(timeStep);
    } catch (const std::exception &exception) {
        AssignError(error, JSBSimErrorModelLoad,
                    [NSString stringWithFormat:@"JSBSim threw while loading '%@': %s", model, exception.what()]);
        return nil;
    }
    os_log_info(JSBSimLog(), "Loaded JSBSim model %{public}@ with dt=%f", model, timeStep);
    return self;
}

- (nullable NSNumber *)handleForProperty:(NSString *)name error:(NSError **)error {
    SGPropertyNode *node = _fdm->GetPropertyManager()->GetNode(name.UTF8String, false);
    if (node == nullptr) {
        AssignError(error, JSBSimErrorUnknownProperty,
                    [NSString stringWithFormat:@"JSBSim property '%@' does not exist in this model", name]);
        return nil;
    }
    _nodes.emplace_back(node);
    return @(static_cast<NSInteger>(_nodes.size() - 1));
}

- (double)valueForHandle:(NSInteger)handle {
    NSAssert(handle >= 0 && static_cast<size_t>(handle) < _nodes.size(), @"Invalid JSBSim property handle %ld", (long)handle);
    return _nodes[static_cast<size_t>(handle)]->getDoubleValue();
}

- (void)setValue:(double)value forHandle:(NSInteger)handle {
    NSAssert(handle >= 0 && static_cast<size_t>(handle) < _nodes.size(), @"Invalid JSBSim property handle %ld", (long)handle);
    _nodes[static_cast<size_t>(handle)]->setDoubleValue(value);
}

- (BOOL)resetToLatitude:(double)latitudeDegrees
              longitude:(double)longitudeDegrees
       terrainElevation:(double)terrainElevationFeet
            altitudeAGL:(double)altitudeAGLFeet
                heading:(double)headingDegrees
     calibratedAirspeed:(double)airspeedKnots
        flightPathAngle:(double)flightPathAngleDegrees
                  error:(NSError **)error {
    try {
        auto ic = _fdm->GetIC();
        // Map coordinates are geodetic (WGS-84); SetLatitudeDegIC would treat them as geocentric (~20 km off here).
        ic->SetGeodLatitudeDegIC(latitudeDegrees);
        ic->SetLongitudeDegIC(longitudeDegrees);
        ic->SetTerrainElevationFtIC(terrainElevationFeet);
        ic->SetAltitudeAGLFtIC(altitudeAGLFeet);
        ic->SetPsiDegIC(headingDegrees);
        ic->SetThetaDegIC(0.0);
        ic->SetPhiDegIC(0.0);
        ic->SetVcalibratedKtsIC(airspeedKnots);
        ic->SetFlightPathAngleDegIC(flightPathAngleDegrees);
        _fdm->ResetToInitialConditions(0);
    } catch (const std::exception &exception) {
        AssignError(error, JSBSimErrorInitialConditions,
                    [NSString stringWithFormat:@"JSBSim rejected the initial conditions: %s", exception.what()]);
        return NO;
    }
    return YES;
}

- (BOOL)trimWithMode:(JSBSimTrimMode)mode error:(NSError **)error {
    try {
        _fdm->DoTrim(static_cast<int>(mode));
    } catch (const std::exception &exception) {
        AssignError(error, JSBSimErrorTrim,
                    [NSString stringWithFormat:@"JSBSim trim (mode %ld) failed: %s", (long)mode, exception.what()]);
        return NO;
    }
    return YES;
}

- (BOOL)runSteps:(NSInteger)steps error:(NSError **)error {
    try {
        for (NSInteger i = 0; i < steps; i++) {
            if (!_fdm->Run()) {
                AssignError(error, JSBSimErrorStep, @"JSBSim stopped running (Run() returned false)");
                return NO;
            }
        }
    } catch (const std::exception &exception) {
        AssignError(error, JSBSimErrorStep,
                    [NSString stringWithFormat:@"JSBSim threw during a time step: %s", exception.what()]);
        return NO;
    }
    return YES;
}

@end
