import ModuleA

// Both generated reports compile into their respective targets; printing them
// is the spike's readout. AlphaService is used so ModuleA isn't dead-stripped.
print(SpikeReport_App.text)
print()
print(SpikeReport_ModuleA.text)
print()
print("runtime sanity: \(AlphaService().name)")
