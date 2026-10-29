# -*- coding: utf-8 -*-
"""GUI 冒烟测试: 窗口创建后 2 秒自动关闭, 验证无运行错误。"""
import os
os.environ["SICN_GUI_TEST"] = "1"
import importlib.util
spec = importlib.util.spec_from_file_location("gui", r"F:\开发\蓝牙设备\sicn_gui.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.main()
print("GUI SMOKE TEST PASSED")
