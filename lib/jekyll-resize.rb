require "digest"
require "fileutils"
require "mini_magick"

module Jekyll
  module Resize
    CACHE_DIR = "cache/resize/"
    HASH_LENGTH = 32

    PERCENT_RE = /\A\s*\d+(?:\.\d+)?%\s*\z/

    def _options_slug(options)
      s = options.to_s.strip.downcase
      # Preserve meaning for cache key:
      #  - "%" becomes "pct" so "50%" != "50>"
      #  - "." becomes "p" so "12.5%" is stable
      s = s.gsub("%", "pct").gsub(".", "p")
      s.gsub(/[^0-9a-z]+/i, "")
    end

    # Generate output image filename.
    def _dest_filename(src_path, options)
      hash = Digest::SHA256.file(src_path)
      short_hash = hash.hexdigest[0, HASH_LENGTH]

      options_slug = _options_slug(options)
      ext = File.extname(src_path)

      "#{short_hash}_#{options_slug}#{ext}"
    end

    # Build the path strings.
    def _paths(repo_base, img_path, options)
      src_path = File.join(repo_base, img_path)
      raise "Image at #{src_path} is not readable" unless File.readable?(src_path)

      dest_dir = File.join(repo_base, CACHE_DIR)
      dest_filename = _dest_filename(src_path, options)
      dest_path = File.join(dest_dir, dest_filename)
      dest_path_rel = File.join(CACHE_DIR, dest_filename)

      [src_path, dest_path, dest_dir, dest_filename, dest_path_rel]
    end

    # Determine whether the image needs to be written.
    def _must_create?(src_path, dest_path)
      !File.exist?(dest_path) || File.mtime(dest_path) <= File.mtime(src_path)
    end

    def _percent_to_geometry(image, percent_options)
      percent = percent_options.to_s.strip.delete_suffix("%").to_f
      raise "Resize percentage must be > 0 (got #{percent_options.inspect})" if percent <= 0

      # Ensure orientation is applied before reading dimensions.
      width, height = image.dimensions

      new_w = [(width * percent / 100.0).round, 1].max
      new_h = [(height * percent / 100.0).round, 1].max

      "#{new_w}x#{new_h}"
    end

    # Read, process, and write out as new image.
    def _process_img(src_path, options, dest_path)
      image = MiniMagick::Image.open(src_path)
      image.auto_orient

      opts = options.to_s.strip
      if opts.match?(PERCENT_RE)
        # Convert "50%" into pixel geometry based on the original image.
        opts = _percent_to_geometry(image, opts)
      end

      image.resize opts
      image.strip
      image.write dest_path
    end

    # Liquid filter entry-point.
    def resize(source, options)
      raise "`source` must be a string - got: #{source.class}" unless source.is_a?(String)
      raise "`source` may not be empty" if source.empty?
      raise "`options` must be a string - got: #{options.class}" unless options.is_a?(String)
      raise "`options` may not be empty" if options.empty?

      site = @context.registers[:site]
      src_path, dest_path, dest_dir, dest_filename, dest_path_rel =
        _paths(site.source, source, options)

      FileUtils.mkdir_p(dest_dir)

      if _must_create?(src_path, dest_path)
        puts "Resizing '#{source}' to '#{dest_path_rel}' - using options: '#{options}'"
        _process_img(src_path, options, dest_path)
        site.static_files << Jekyll::StaticFile.new(site, site.source, CACHE_DIR, dest_filename)
      end

      File.join(site.baseurl, dest_path_rel)
    end
  end
end

Liquid::Template.register_filter(Jekyll::Resize)
