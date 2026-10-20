// Minimal simulator app: verifies the packaged interpreter and extension loader.
// No LumeBox IPA is built or uploaded by this check.
#import <UIKit/UIKit.h>
#include <Python.h>

static PyObject *NoNetwork(PyObject *self, PyObject *args) {
  PyErr_SetString(PyExc_RuntimeError, "Smoke test forbids network");
  return NULL;
}
static PyMethodDef Methods[] = {{"invoke", NoNetwork, METH_VARARGS, NULL}, {NULL, NULL, 0, NULL}};
static struct PyModuleDef Module = {PyModuleDef_HEAD_INIT, "_lume_host", NULL, -1, Methods};
static PyObject *InitHost(void) { return PyModule_Create(&Module); }

@interface SmokeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation SmokeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [[UIViewController alloc] init];
  [self.window makeKeyAndVisible];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *root = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"python"];
    NSString *standard = [root stringByAppendingPathComponent:@"lib/python3.13"];
    PyImport_AppendInittab("_lume_host", InitHost);
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    config.module_search_paths_set = 1;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, root.UTF8String);
    for (NSString *path in @[standard, [standard stringByAppendingPathComponent:@"lib-dynload"], [root stringByAppendingPathComponent:@"packages"], root]) {
      wchar_t *wide = Py_DecodeLocale(path.UTF8String, NULL);
      status = PyWideStringList_Append(&config.module_search_paths, wide);
      PyMem_RawFree(wide);
      if (PyStatus_Exception(status)) break;
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) { fprintf(stderr, "LUME_PYTHON_SMOKE_FAILED init\n"); exit(1); }
    const char *test =
      "import json, ssl, ctypes, hashlib, bs4, requests, lume_python\n"
      "assert ssl.OPENSSL_VERSION and hashlib.sha256(b'smoke').hexdigest()\n"
      "script = '''from base.spider import Spider\n"
      "class Spider(Spider):\n"
      " def init(self, extend): pass\n"
      " def homeContent(self, filter): return {'class':[{'type_id':'1','type_name':'Movie'}]}\n"
      " def categoryContent(self, *args): return {'list':[]}\n"
      " def detailContent(self, ids): return {'list':[]}\n"
      " def playerContent(self, *args): return {}\n'''\n"
      "loaded = json.loads(lume_python.run(json.dumps({'sourceId':'smoke','action':'load','script':script})))\n"
      "assert loaded['ok'], loaded\n"
      "called = json.loads(lume_python.run(json.dumps({'sourceId':'smoke','action':'call','method':'categories'})))\n"
      "assert called['ok'] and called['value'][0]['title'] == 'Movie', called\n";
    int code = PyRun_SimpleString(test);
    fprintf(stderr, code == 0 ? "LUME_PYTHON_SMOKE_OK\n" : "LUME_PYTHON_SMOKE_FAILED script\n");
    fflush(stderr);
    exit(code == 0 ? 0 : 1);
  });
  return YES;
}
@end

int main(int argc, char **argv) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(SmokeDelegate.class)); }
}
