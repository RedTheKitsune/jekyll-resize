require "digest"
require "fileutils"
require "mini_magick"

module Jekyll
  module Resize
    CACHE_DIR   = "cache/resize/".freeze
    HASH_LENGTH = 32

    PERCENT_RE = /\A\s*\d+(?:\.\d+)?%\s*\z/.freeze

    # Supported output formats (normalized)
    SUPPORTED_FORMATS = {
      "jpg"  => "jpg",
      "jpeg" => "jpg",
      "webp" => "webp"
    }.freeze

    def _options_slug(options)
      s = options.to_s.strip.downcase
      # Keep cache key stable and filesystem-safe
      s = s.gsub("%", "pct").gsub(".", "p")
      s.gsub(/[^0-9a-z]+/i, "")
    end

    def _normalize_format(fmt)
      return nil if fmt.nil?

      f = fmt.to_s.strip.downcase
      return nil if f.empty?

      normalized = SUPPORTED_FORMATS[f]
      raise "Unsupported output format '#{fmt}'. Supported: jpg, webp" unless normalized
      normalized
    end

    # Accepts either:
    # - third arg: resize: "800x800", "webp"
    # - embedded in options:
    #   "800x800|webp", "800x800 webp", "800x800,webp", "800x800 format=webp"
    def _parse_resize_and_format(options, explicit_format = nil)
      raw = options.to_s.strip

      fmt = _normalize_format(explicit_format)
      opts = raw.dup

      if fmt.nil?
        # format=webp / format=jpg (at end)
        if (m = opts.match(/(?:^|[\s|,])format\s*=\s*([a-z0-9]+)\s*$/i))
          fmt = _normalize_format(m[1])
          opts = opts.sub(m[0], "").strip
        end
      end

      if fmt.nil?
        # Delimiter forms: "800x800|webp" or "800x800,webp"
        parts = opts.split(/[|,]/).map(&:strip)
        if parts.length >= 2 && SUPPORTED_FORMATS.key?(parts.last.downcase)
          fmt = _normalize_format(parts.last)
          parts.pop
          opts = parts.join("|").strip
        end
      end

      if fmt.nil?
        # Whitespace form: "800x800 webp"
        parts = opts.split(/\s+/)
        if parts.length >= 2 && SUPPORTED_FORMATS.key?(parts.last.downcase)
          fmt = _normalize_format(parts.last)
          parts.pop
          opts = parts.join(" ").strip
        end
      end

      # Use a cache key that changes when output format changes
      cache_key_opts = fmt ? "#{opts} format=#{fmt}" : opts

      [opts, fmt, cache_key_opts]
    end

    def _dest_filename(src_path, cache_key_options, out_ext = nil)
      hash = Digest::SHA256.file(src_path)
      short_hash = hash.hexdigest[0, HASH_LENGTH]
      options_slug = _options_slug(cache_key_options)

      ext =
        if out_ext && !out_ext.to_s.empty?
          out_ext.start_with?(".") ? out_ext : ".#{out_ext}"
        else
          File.extname(src_path)
        end

      "#{short_hash}_#{options_slug}#{ext}"
    end

    def _paths(repo_base, img_path, cache_key_options, out_ext = nil)
      src_path = File.join(repo_base, img_path)
      raise "Image at #{src_path} is not readable" unless File.readable?(src_path)

      dest_dir = File.join(repo_base, CACHE_DIR)
      dest_filename = _dest_filename(src_path, cache_key_options, out_ext)
      dest_path = File.join(dest_dir, dest_filename)
      dest_path_rel = File.join(CACHE_DIR, dest_filename)

      [src_path, dest_path, dest_dir, dest_filename, dest_path_rel]
    end

    def _must_create?(src_path, dest_path)
      !File.exist?(dest_path) || File.mtime(dest_path) <= File.mtime(src_path)
    end

    def _percent_to_geometry(image, percent_options)
      percent = percent_options.to_s.strip.delete_suffix("%").to_f
      raise "Resize percentage must be > 0 (got #{percent_options.inspect})" if percent <= 0

      w, h = image.dimensions
      new_w = [(w * percent / 100.0).round, 1].max
      new_h = [(h * percent / 100.0).round, 1].max
      "#{new_w}x#{new_h}"
    end

    def _process_img(src_path, resize_opts, dest_path, out_format = nil)
      image = MiniMagick::Image.open(src_path)
      image.auto_orient

      opts = resize_opts.to_s.strip
      if opts.match?(PERCENT_RE)
        opts = _percent_to_geometry(image, opts)
      end

      image.resize opts
      image.strip

      # If converting to JPG, put transparency on white (avoid black background)
      if out_format == "jpg"
        image.combine_options do |c|
          c.background "white"
          c.alpha "remove"
          c.alpha "off"
        end
      end

      image.format out_format if out_format
      image.write dest_path
    end

    # Liquid filter:
    #   {{ "/assets/a.png" | resize: "800x800" }}
    #   {{ "/assets/a.png" | resize: "800x800", "webp" }}
    #   {{ "/assets/a.png" | resize: "800x800|webp" }}
    def resize(source, options, format = nil)
      raise "`source` must be a string - got: #{source.class}" unless source.is_a?(String)
      raise "`source` may not be empty" if source.empty?
      raise "`options` must be a string - got: #{options.class}" unless options.is_a?(String)
      raise "`options` may not be empty" if options.empty?
      raise "`format` must be a string - got: #{format.class}" unless format.nil? || format.is_a?(String)

      site = @context.registers[:site]

      resize_opts, out_fmt, cache_key_opts = _parse_resize_and_format(options, format)
      out_ext = out_fmt ? ".#{out_fmt}" : nil

      src_path, dest_path, dest_dir, dest_filename, dest_path_rel =
        _paths(site.source, source, cache_key_opts, out_ext)

      FileUtils.mkdir_p(dest_dir)

      if _must_create?(src_path, dest_path)
        puts "Resizing '#{source}' to '#{dest_path_rel}' - using options: '#{options}'#{out_fmt ? " (format=#{out_fmt})" : ""}"
        _process_img(src_path, resize_opts, dest_path, out_fmt)
        site.static_files << Jekyll::StaticFile.new(site, site.source, CACHE_DIR, dest_filename)
      end

      File.join(site.baseurl, dest_path_rel)
    end
  end
end

Liquid::Template.register_filter(Jekyll::Resize)
