int main() {
  std::string line; int ok = 0, n = 0;
  while (std::getline(std::cin, line)) {
    n++; uint32_t key; int ttl; size_t ts, te;
    if (!parseHeader(line.c_str(), line.size(), key, ttl, ts, te)) { fprintf(stderr, "REJECT %.40s\n", line.c_str()); continue; }
    char out[1500];
    size_t len = withTtl(line.c_str(), line.size(), ts, te, ttl - 1, out);
    fprintf(stderr, "ttl=%d key=%08x len %zu->%zu\n", ttl, key, line.size(), len);
    puts(out); ok++;
  }
  fprintf(stderr, "%d/%d parsed\n", ok, n);
}
