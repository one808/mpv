// Compatibility shim for MinGW i686 which lacks std::to_chars/from_chars
// for floating-point types in libstdc++
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace std {

from_chars_result from_chars(const char* first, const char* last,
                              float& value, chars_format fmt) {
    char buf[64];
    size_t len = last - first;
    if (len >= sizeof(buf)) return {last, errc::result_out_of_range};
    memcpy(buf, first, len);
    buf[len] = '\0';
    char* end;
    double d = strtod(buf, &end);
    if (end == buf) return {last, errc::invalid_argument};
    value = (float)d;
    return {first + (end - buf), errc{}};
}

from_chars_result from_chars(const char* first, const char* last,
                              double& value, chars_format fmt) {
    char buf[64];
    size_t len = last - first;
    if (len >= sizeof(buf)) return {last, errc::result_out_of_range};
    memcpy(buf, first, len);
    buf[len] = '\0';
    char* end;
    double d = strtod(buf, &end);
    if (end == buf) return {last, errc::invalid_argument};
    value = d;
    return {first + (end - buf), errc{}};
}

to_chars_result to_chars(char* first, char* last, float value) {
    int n = snprintf(first, last - first, "%g", value);
    if (n < 0 || first + n >= last) return {last, errc::value_too_large};
    return {first + n, errc{}};
}

to_chars_result to_chars(char* first, char* last, double value) {
    int n = snprintf(first, last - first, "%g", value);
    if (n < 0 || first + n >= last) return {last, errc::value_too_large};
    return {first + n, errc{}};
}

} // namespace std
