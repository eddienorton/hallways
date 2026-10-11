import sys
from pxr import Usd, UsdGeom, UsdUtils, Sdf
src, dst = sys.argv[1], sys.argv[2]
stage = Usd.Stage.Open(src)
UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
UsdGeom.SetStageMetersPerUnit(stage, 1.0)
stage.GetRootLayer().Save()
print('upAxis', UsdGeom.GetStageUpAxis(stage), 'default', stage.GetDefaultPrim().GetPath())
ok = UsdUtils.CreateNewARKitUsdzPackage(Sdf.AssetPath(src), dst)
print('usdz', ok)
