// Read-only adapter for the locally installed Jianying engine.
// No application libraries are bundled and no draft/application file is changed.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <sys/stat.h>

using Decoder = std::string (*)(void *, const std::string &, const std::string &, bool &);
using Encoder = std::string (*)(void *, const std::string &);
using Enable = void (*)(void *, bool);
static constexpr const char *symbol = "_ZN4lvve12EncryptUtils7decryptERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEES9_Rb";
static constexpr const char *encryptSymbol = "_ZN4lvve12EncryptUtils7encryptERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE";
static constexpr const char *enableSymbol = "_ZN4lvve12EncryptUtils6enableEb";

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    const bool encode = argc > 1 && std::string(argv[1]) == "--encode";
    if (argc != (encode ? 5 : 4)) {
      std::cerr << "Usage: draft_decode [--encode] /path/to/libvideoeditor.dylib INPUT OUTPUT\n"
                << "OUTPUT must not exist; INPUT and application are read only.\n";
      return 2;
    }
    const int shift = encode ? 1 : 0;
    const char *enginePath = argv[1 + shift];
    const char *inputPath = argv[2 + shift];
    const char *outputPath = argv[3 + shift];
    struct stat existing;
    if (lstat(outputPath, &existing) == 0 || errno != ENOENT) {
      std::cerr << "OUTPUT must be a new file\n"; return 7;
    }
    std::ifstream in(inputPath, std::ios::binary);
    if (!in) { std::cerr << "Cannot read input\n"; return 3; }
    in.seekg(0, std::ios::end);
    auto size = in.tellg();
    if (size <= 0 || size > 512LL * 1024 * 1024) {
      std::cerr << "Empty input or exceeds 512 MiB limit\n"; return 3;
    }
    in.seekg(0, std::ios::beg);
    const std::string input((std::istreambuf_iterator<char>(in)), {});
    NSData *inputData = [NSData dataWithBytes:input.data() length:input.size()];
    NSError *error = nil;
    id plain = [NSJSONSerialization JSONObjectWithData:inputData options:0 error:&error];
    std::string decoded;
    if (!encode && [plain isKindOfClass:[NSDictionary class]]) {
      decoded = input;
    } else {
      if (encode && ![plain isKindOfClass:[NSDictionary class]]) {
        std::cerr << "Encoding requires a valid JSON object input\n"; return 6;
      }
      void *library = dlopen(enginePath, RTLD_NOW | RTLD_LOCAL);
      if (!library) { std::cerr << "Cannot load installed engine: " << dlerror() << '\n'; return 4; }
      auto decode = reinterpret_cast<Decoder>(dlsym(library, symbol));
      if (!decode) { std::cerr << "Installed engine decoder ABI not supported\n"; return 4; }
      bool ok = false;
      alignas(16) unsigned char instance[64] = {};
      try {
        if (encode) {
          auto encrypt = reinterpret_cast<Encoder>(dlsym(library, encryptSymbol));
          auto enable = reinterpret_cast<Enable>(dlsym(library, enableSymbol));
          if (!encrypt || !enable) { std::cerr << "Installed engine encoder ABI not supported\n"; return 4; }
          enable(instance, true);
          decoded = encrypt(instance, input);
          const auto roundtrip = decode(instance, decoded, "{}", ok);
          if (!ok || roundtrip != input) {
            std::cerr << "Encoded output failed exact decode roundtrip; no output written\n"; return 5;
          }
        } else {
          decoded = decode(instance, input, "{}", ok);
        }
      }
      catch (...) { std::cerr << "Installed engine raised an exception\n"; return 5; }
      if (!ok || decoded.empty()) { std::cerr << "Installed engine could not decode this file\n"; return 5; }
      // Deliberately do not dlclose the app engine while its C++ objects may exist.
    }
    if (!encode) {
      NSData *data = [NSData dataWithBytes:decoded.data() length:decoded.size()];
      error = nil;
      id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
      if (![object isKindOfClass:[NSDictionary class]]) {
        std::cerr << "Decoded content is not a valid JSON object; no output written\n";
        return 6;
      }
    }
    int fd = open(outputPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) { std::cerr << "Cannot create a new output file: " << strerror(errno) << '\n'; return 7; }
    size_t offset = 0;
    while (offset < decoded.size()) {
      ssize_t n = write(fd, decoded.data() + offset, decoded.size() - offset);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { close(fd); unlink(outputPath); std::cerr << "Output write failed\n"; return 7; }
      offset += static_cast<size_t>(n);
    }
    if (fsync(fd) < 0) { close(fd); unlink(outputPath); std::cerr << "Output flush failed\n"; return 7; }
    close(fd);
    std::cerr << (encode ? "Encoded with exact roundtrip: " : "Decoded valid JSON: ") << decoded.size() << " bytes\n";
    return 0;
  }
}
