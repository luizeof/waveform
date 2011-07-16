require "ruby-audio"

begin
  require "oily_png"
rescue LoadError
  require "chunky_png"
end

class Waveform
  VERSION = "0.0.1"
  
  DefaultOptions = {
    :method => :peak,
    :width => 1800,
    :height => 280,
    :background_color => "#666666",
    :color => "#00ccff"
  }
  
  TransparencyMask = "#00ff00"
  TransparencyAlternate = "#ffff00" # in case the mask is the background color!
  
  attr_reader :audio
  
  # Scope these under Waveform so you can catch the ones generated by just this
  # class.
  class RuntimeError < ::RuntimeError;end;
  class ArgumentError < ::ArgumentError;end;
  
  # Setup a new Waveform for the given audio file. If given anything besides a
  # WAV file it will attempt to first convert the file to a WAV using ffmpeg.
  # 
  # Optionally takes an IO stream to which it will print log/benchmarking info.
  # 
  # See #generate for how to generate the waveform image from the given audio
  # file.
  # 
  # Available conversions depend on your installation of ffmpeg.
  # 
  # Example:
  # 
  #   Waveform.new("mp3s/Kickstart My Heart.mp3")
  #   Waveform.new("mp3s/Kickstart My Heart.mp3", $stdout)
  # 
  def initialize(audio, log=nil)
    raise ArgumentError.new("No source audio filename given, must be an existing sound file.") unless audio
    raise RuntimeError.new("Source audio file '#{audio}' not found.") unless File.exist?(audio)
    
    @log = Log.new(log)

    if File.extname(audio) != ".wav"
      @audio = audio.sub /(.+)\.(.+)/, "\\1.wav"
      raise RuntimeError.new("Unable to decode source '#{audio}' to WAV. Do you have ffmpeg installed with an appropriate decoder for your source file?") unless to_wav(audio, @audio)
    else
      @audio = audio
    end
  end
  
  # Generate a Waveform image at the given filename with the given options.
  # 
  # Available options are:
  # 
  #   :method => The method used to read sample frames, available methods
  #     are peak and rms. peak is probably what you're used to seeing, it uses
  #     the maximum amplitude per sample to generate the waveform, so the
  #     waveform looks more dynamic. RMS gives a more fluid waveform and
  #     probably more accurately reflects what you hear, but isn't as
  #     pronounced (typically).
  #     
  #     Can be :rms or :peak
  #     Default is :peak.
  # 
  #   :width => The width (in pixels) of the final waveform image.
  #     Default is 1800.
  # 
  #   :height => The height (in pixels) of the final waveform image.
  #     Default is 280.
  # 
  #   :background_color => Hex code of the background color of the generated
  #     waveform image.
  #     Default is #666666 (gray).
  #
  #   :color => Hex code of the color to draw the waveform, or can pass
  #     :transparent to render the waveform transparent (use w/ a solid
  #     color background to achieve a "cutout" effect).
  #     Default is #00ccff (cyan-ish).
  #
  # Example:
  #   waveform = Waveform.new("mp3s/Kickstart My Heart.mp3")
  # 
  #   waveform.generate("waves/Kickstart My Heart.png")
  #   waveform.generate("waves/Kickstart My Heart.png", :method => :rms)
  #   waveform.generate("waves/Kickstart My Heart.png", :color => "#ff00ff")
  # 
  def generate(filename, options={})
    raise ArgumentError.new("No destination filename given for waveform") unless filename
    raise RuntimeError.new("Destination file #{filename} exists") if File.exists?(filename)

    options = DefaultOptions.merge(options)
    
    @log.start!
    
    # Frames gives the amplitudes for each channel, for our waveform we're
    # saying the "visual" amplitude is the average of the amplitude across all
    # the channels. This might be a little weird w/ the "peak" method if the
    # frames are very wide (i.e. the image width is very small) -- I *think*
    # the larger the frames are, the more "peaky" the waveform should get,
    # perhaps to the point of inaccurately reflecting the actual sound.
    samples = frames(options[:width], options[:method]).collect do |frame|
      frame.inject(0.0) { |sum, peak| sum + peak } / frame.size
    end
    
    @log.timed("\nDrawing...") do
      background_color = options[:background_color] == :transparent ? ChunkyPNG::Color::TRANSPARENT : options[:background_color]
      
      if options[:color] == :transparent
        color = transparent = ChunkyPNG::Color.from_hex(
          # Have to do this little bit because it's possible the color we were
          # intending to use a transparency mask *is* the background color, and
          # then we'd end up wiping out the whole image.
          options[:background_color].downcase == TransparencyMask ? TransparencyAlternate : TransparencyMask
        )
      else
        color = ChunkyPNG::Color.from_hex(options[:color])
      end

      image = ChunkyPNG::Image.new(options[:width], options[:height], background_color)
      # Calling "zero" the middle of the waveform, like there's positive and
      # negative amplitude
      zero = options[:height] / 2.0
      
      samples.each_with_index do |sample, x|
        # Half the amplitude goes above zero, half below
        amplitude = sample * options[:height].to_f / 2.0
        # If you give ChunkyPNG floats for pixel positions all sorts of things
        # go haywire.
        image.line(x, (zero - amplitude).round, x, (zero + amplitude).round, color)
      end
      
      # Simple transparency masking, it just loops over every pixel and makes
      # ones which match the transparency mask color completely clear.
      if transparent
        (0..image.width - 1).each do |x|
          (0..image.height - 1).each do |y|
            image[x, y] = ChunkyPNG::Color.rgba(0, 0, 0, 0) if image[x, y] == transparent
          end
        end
      end
      
      image.save(filename)
    end

    @log.done!("Generated waveform '#{filename}'")
  end
  
  # Returns a sampling of frames from the given wave file using the given method
  # the sample size is determined by the given pixel width -- we want one sample
  # frame per horizontal pixel.
  def frames(width, method = :peak)
    raise ArgumentError.new("Unknown sampling method #{method}") unless [ :peak, :rms ].include?(method)
    
    frames = []
    
    RubyAudio::Sound.open(audio) do |snd|
      frames_read       = 0
      frames_per_sample = (snd.info.frames.to_f / width.to_f).to_i
      sample            = RubyAudio::Buffer.new("float", frames_per_sample, snd.info.channels)

      @log.timed("Sampling #{frames_per_sample} frames per sample: ") do
        while(frames_read = snd.read(sample)) > 0
          frames << send(method, sample, snd.info.channels)
          @log.out(".")
        end
      end
    end
  
    frames
  end
  
  private
  
  # Decode audio to a wav file, returns true if the decode succeeded or false
  # otherwise.
  def to_wav(src, dest)
    @log.start!
    @log.out("Decoding source audio '#{src}' to WAV...")

    raise RuntimeError.new("Destination WAV file '#{dest}' exists!") if File.exists?(dest)
    
    system %Q{ffmpeg -i "#{src}" -f wav "#{dest}" > /dev/null 2>&1}
    @log.done!
    
    File.exists?(dest)
  end
  
  # Returns an array of the peak of each channel for the given collection of
  # frames -- the peak is individual to the channel, and the returned collection
  # of peaks are not (necessarily) from the same frame(s).
  def peak(frames, channels=1)
    peak_frame = []
    (0..channels-1).each do |channel|
      peak_frame << channel_peak(frames, channel)
    end
    peak_frame
  end

  # Returns an array of rms values for the given frameset where each rms value is
  # the rms value for that channel.
  def rms(frames, channels=1)
    rms_frame = []
    (0..channels-1).each do |channel|
      rms_frame << channel_rms(frames, channel)
    end
    rms_frame
  end
  
  # Returns the peak voltage reached on the given channel in the given collection
  # of frames.
  # 
  # TODO: Could lose some resolution and only sample every other frame, would
  # likely still generate the same waveform as the waveform is so comparitively
  # low resolution to the original input (in most cases), and would increase
  # the analyzation speed (maybe).
  def channel_peak(frames, channel=0)
    peak = 0.0
    frames.each do |frame|
      next if frame.nil?
      peak = frame[channel].abs if frame[channel].abs > peak
    end
    peak
  end

  # Returns the rms value across the given collection of frames for the given
  # channel.
  # 
  # FIXME: this RMS calculation might be wrong...
  # refactored this from: http://pscode.org/javadoc/src-html/org/pscode/ui/audiotrace/AudioPlotPanel.html#line.996
  def channel_rms(frames, channel=0)
    avg = frames.inject(0.0){ |sum, frame| sum += frame ? frame[channel] : 0 }/frames.size.to_f
    Math.sqrt(frames.inject(0.0){ |sum, frame| sum += frame ? (frame[channel]-avg)**2 : 0 }/frames.size.to_f)
  end
end

class Waveform
  # A simple class for logging + benchmarking, nice to have good feedback on a
  # long batch operation.
  # 
  # There's probably 10,000,000 other bechmarking classes, but writing this was
  # easier than using Google.
  class Log
    attr_accessor :io
    
    def initialize(io=$stdout)
      @io = io
    end
    
    # Prints the given message to the log
    def out(msg)
      io.print(msg) if io
    end

    # Prints the given message to the log followed by the most recent benchmark
    # (note that it calls .end! which will stop the benchmark)
    def done!(msg="")
      out "#{msg} (#{self.end!}s)\n"
    end

    # Starts a new benchmark clock and returns the index of the new clock.
    # 
    # If .start! is called again before .end! then the time returned will be
    # the elapsed time from the next call to start!, and calling .end! again
    # will return the time from *this* call to start! (that is, the clocks are
    # LIFO)
    def start!
      (@benchmarks ||= []) << Time.now
      @current = @benchmarks.size - 1
    end

    # Returns the elapsed time from the most recently started benchmark clock
    # and ends the benchmark, so that a subsequent call to .end! will return
    # the elapsed time from the previously started benchmark clock.
    def end!
      elapsed = (Time.now - @benchmarks[@current])
      @current -= 1
      elapsed
    end

    # Returns the elapsed time from the benchmark clock w/ the given index (as
    # returned from when .start! was called).
    def time?(index)
      Time.now - @benchmarks[index]
    end
    
    # Benchmarks the given block, printing out the given message first (if
    # given).
    def timed(message=nil, &block)
      start!
      out(message) if message
      yield
      done!
    end
  end
end
