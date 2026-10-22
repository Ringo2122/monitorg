# encoding: utf-8
require 'json'
require 'fileutils'
require 'digest'

module Store
  ROOT = File.expand_path('..', __dir__)
  DATA = File.join(ROOT, 'data')
  LOTS = File.join(DATA, 'lots.json')
  DET  = File.join(DATA, 'det')
  PH   = File.join(DATA, 'ph')
  W    = 400
  Q    = 48
  NOPHOTO = %w[686379d8aa82afee2005f80e1e4102e0 5c625537dab8d1883b8975ea110f8323 e5832167f583dce4ac156d50bdf19078].freeze

  module_function

  def nophoto?(f)
    File.exist?(f) && NOPHOTO.include?(Digest::MD5.file(f).hexdigest)
  end

  def load
    FileUtils.mkdir_p([DET, PH])
    File.exist?(LOTS) ? JSON.parse(File.read(LOTS, encoding: 'UTF-8')) : []
  end

  def save(lots)
    body = lots.sort_by { |l| l['key'] }.map { |l| JSON.generate(l) }.join(",\n")
    File.write(LOTS, "[\n#{body}\n]\n")
  end

  def fname(key)
    key.bytesize > 240 ? "#{key.byteslice(0, 200).scrub('')}-#{Digest::MD5.hexdigest(key)[0, 12]}" : key
  end

  def det_path(key)
    File.join(DET, "#{fname(key)}.json")
  end

  def ph_path(key)
    File.join(PH, "#{fname(key)}.jpg")
  end

  def details(key)
    f = det_path(key)
    File.exist?(f) ? (JSON.parse(File.read(f, encoding: 'UTF-8')) rescue []) : []
  end

  def save_details(key, secs)
    File.write(det_path(key), JSON.generate(secs))
  end

  def sniff(path)
    head = File.binread(path, 12).to_s
    return 'jpg' if head.start_with?("\xFF\xD8".b)
    return 'png' if head.start_with?("\x89PNG".b)
    return 'gif' if head.start_with?('GIF8')
    return 'webp' if head[0, 4] == 'RIFF' && head[8, 4] == 'WEBP'
    nil
  end

  def shrink(src, dst, w = W, q = Q)
    if system('which sips >/dev/null 2>&1')
      system('sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', q.to_s, '-Z', w.to_s,
             src, '--out', dst, out: File::NULL, err: File::NULL)
    else
      fmt = sniff(src) or return false
      system('convert', "#{fmt}:#{src}[0]", '-auto-orient', '-resize', "#{w}x#{w}>", '-strip',
             '-quality', q.to_s, dst, out: File::NULL, err: File::NULL)
    end
    File.exist?(dst) && File.size(dst) > 700
  end

  def save_photo(urls, key, ua, w = W, q = Q)
    dst = ph_path(key)
    return true if File.exist?(dst)
    raw = dst + '.raw'
    urls.compact.uniq.each do |u|
      next unless u.to_s =~ %r{\Ahttps?://}i
      system('curl', '-sS', '-L', '--proto', '=http,https', '--proto-redir', '=http,https', '--max-filesize', '15000000',
             '-m', '40', '-A', ua, '-o', raw, u, out: File::NULL, err: File::NULL)
      next unless File.exist?(raw) && File.size(raw) > 1000 && !nophoto?(raw)
      ok = shrink(raw, dst, w, q)
      File.delete(raw) if File.exist?(raw)
      File.delete(dst) if ok && nophoto?(dst)
      return true if ok && File.exist?(dst)
    end
    File.delete(raw) if File.exist?(raw)
    false
  end
end
