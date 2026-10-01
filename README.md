# ContinuousGlucoseMonitorServiceKit

ContinuousGlucoseMonitorServiceKit implements the [Bluetooth Continuous Glucose Monitoring Service 1.0.2 (CGMS)](https://www.bluetooth.com/specifications/specs/continuous-glucose-monitoring-service-1-0-2/) and the companion [Continuous Glucose Monitoring Profile 1.0.2 (CGMP)](https://www.bluetooth.com/specifications/specs/continuous-glucose-monitoring-profile-1-0-2/).

`Sources/ContinuousGlucoseMonitorServiceKit/Service` holds the characteristic UUIDs and the wire codecs for every CGMS characteristic (CGM Measurement, Feature, Status, Session Start Time, Session Run Time) plus the Record Access Control Point and CGM Specific Ops Control Point constants. The codecs are shared by a CGM sensor (GATT server) and a collector (GATT client) so both sides encode and decode identically, and can be used to support rapid development and testing of CGM sensors and collectors that also use CGMS.

Depends on [BluetoothCommonKit](https://github.com/tidepool-org/BluetoothCommonKit) for ACS, SFLOAT, E2E-CRC, Date Time helpers and the GATT server / peripheral plumbing.
