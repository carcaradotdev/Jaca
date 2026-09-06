// Squeeze in-process network capture agent (native JVMTI bootstrap).
//
// On attach to a debuggable app via `cmd activity attach-agent <pid> <so>=<opts>`,
// ART calls Agent_OnAttach. We:
//   1. acquire a JVMTI env,
//   2. add our Kotlin/Java agent dex to the system class loader search,
//   3. call com.squeeze.agent.SqueezeAgent.attach(socketName) via JNI.
//
// `options` (the part after '=' in the attach spec) is "<dexPath>,<socketName>".
#include <jni.h>
#include <jvmti.h>
#include <android/log.h>
#include <cstring>
#include <string>
#include <unistd.h>

#include "squeeze_transform.h"

#define LOG_TAG "SqueezeAgent"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

jint AttachAgent(JavaVM* vm, char* options) {
  LOGI("Agent_OnAttach: pid=%d options=%s", getpid(), options ? options : "(null)");

  jvmtiEnv* jvmti = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&jvmti), JVMTI_VERSION_1_2) != JNI_OK || jvmti == nullptr) {
    LOGE("Failed to get JVMTI env");
    return JNI_OK;
  }

  // Parse "<bootDex>,<captureDex>,<socketName>".
  std::string opts = options ? options : "";
  std::string bootDex, captureDex, socketName = "squeeze_agent";
  auto c1 = opts.find(',');
  auto c2 = (c1 == std::string::npos) ? std::string::npos : opts.find(',', c1 + 1);
  if (c1 != std::string::npos && c2 != std::string::npos) {
    bootDex = opts.substr(0, c1);
    captureDex = opts.substr(c1 + 1, c2 - c1 - 1);
    socketName = opts.substr(c2 + 1);
  } else {
    bootDex = opts;
  }

  if (!bootDex.empty()) {
    // Only the tiny Java trampoline goes on the bootstrap loader (so hooks in boot
    // classes like java.net.URL can resolve SqueezeHooks). The Kotlin capture dex
    // is loaded later on an isolated loader (see SqueezeAgent.attach).
    jvmtiError err = jvmti->AddToBootstrapClassLoaderSearch(bootDex.c_str());
    LOGI("AddToBootstrapClassLoaderSearch(%s) -> %d", bootDex.c_str(), err);
    // On re-attach the boot dex is already present (err != NONE) — that's fine,
    // continue so we can re-point the reporter to the new socket.
  }

  JNIEnv* jni = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&jni), JNI_VERSION_1_6) != JNI_OK || jni == nullptr) {
    LOGE("Failed to get JNI env");
    return JNI_OK;
  }

  // Set up the bytecode-instrumentation engine and register our hooks BEFORE
  // invoking the Java entrypoint (which self-tests a hooked method).
  squeeze::InitTransforms(jvmti);
  jclass urlClass = jni->FindClass("java/net/URL");  // boot class — findable from agent
  if (urlClass != nullptr) {
    squeeze::RegisterExitHook(jvmti, jni, urlClass, "openConnection", "()Ljava/net/URLConnection;");
  } else {
    if (jni->ExceptionCheck()) jni->ExceptionClear();
    LOGE("Could not find java/net/URL");
  }
  // OkHttp3 lives on the app loader (can't FindClass it from the agent). Hook
  // networkInterceptors() by name so the capture can inject its interceptor —
  // this is where the bulk of modern app traffic (incl. ktor-over-OkHttp) flows.
  squeeze::RegisterExitHookByName(jvmti, jni, "Lokhttp3/OkHttpClient;",
                                  "networkInterceptors", "()Ljava/util/List;");
  // Also hook the APPLICATION interceptor list. It runs before a connection exists, so it's
  // the only layer where a request may be repointed at a different host/port (okhttp throws
  // "must retain the same host and port" if a network interceptor tries). Capture still runs
  // on the network list; this one exists so the agent can rewrite a request.
  squeeze::RegisterExitHookByName(jvmti, jni, "Lokhttp3/OkHttpClient;",
                                  "interceptors", "()Ljava/util/List;");
  // OkHttp2 (com.squareup.okhttp) for older apps/libraries — same hook, the capture
  // routes by the declaring class in the method signature.
  squeeze::RegisterExitHookByName(jvmti, jni, "Lcom/squareup/okhttp/OkHttpClient;",
                                  "networkInterceptors", "()Ljava/util/List;");

  // Our dex is on the bootstrap loader, so FindClass (agent context → bootstrap)
  // resolves it directly.
  jclass cls = jni->FindClass("com/squeeze/agent/SqueezeAgent");
  if (cls == nullptr || jni->ExceptionCheck()) {
    if (jni->ExceptionCheck()) { jni->ExceptionDescribe(); jni->ExceptionClear(); }
    LOGE("Could not load com.squeeze.agent.SqueezeAgent from bootstrap");
    return JNI_OK;
  }
  jmethodID attach = jni->GetStaticMethodID(cls, "attach", "(Ljava/lang/String;Ljava/lang/String;)V");
  if (attach == nullptr) {
    if (jni->ExceptionCheck()) jni->ExceptionClear();
    LOGE("Could not find SqueezeAgent.attach(String,String)");
    return JNI_OK;
  }
  jstring jCapture = jni->NewStringUTF(captureDex.c_str());
  jstring jSock = jni->NewStringUTF(socketName.c_str());
  jni->CallStaticVoidMethod(cls, attach, jCapture, jSock);
  if (jni->ExceptionCheck()) {
    jni->ExceptionDescribe();
    jni->ExceptionClear();
    LOGE("SqueezeAgent.attach threw");
  } else {
    LOGI("SqueezeAgent.attach invoked (capture=%s socket=%s)", captureDex.c_str(), socketName.c_str());
  }
  jni->DeleteLocalRef(jCapture);
  jni->DeleteLocalRef(jSock);
  return JNI_OK;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Agent_OnAttach(JavaVM* vm, char* options, void* reserved) {
  return AttachAgent(vm, options);
}

extern "C" JNIEXPORT jint JNICALL
Agent_OnLoad(JavaVM* vm, char* options, void* reserved) {
  return AttachAgent(vm, options);
}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
  return JNI_VERSION_1_6;
}
