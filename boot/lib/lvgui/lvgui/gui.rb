module LVGUI
  # Refreshing at 120 times per second *really* helps with the drag operations
  # responsiveness. At 60 it feels a bit sluggish.
  # This likely comes from the naïve implementation that we are not refreshing at
  # 60 times per seconds, but rather, refresh and wait 1/60th of a second. This
  # makes the refresh rate a tad slower.
  # Boosting to 120 doesn't seem to have ill effects. It's simply refreshed more.
  REFRESH_RATE = 120

  # UI constants
  NIXOS_LIGHT_HUE = 205
  NIXOS_DARK_HUE  = 220

  # Sets things up; back box for some ugly hacks.
  def self.init()
    return if @initialized
    @initialized = true

    # This is used by the "simulator".
    if Args.get(:resolution)
      pair = Args.get(:resolution).split("x")
      unless pair.length == 2
        $stderr.puts "--resolution <width>x<height>"
        exit 2
      end
      LVGL::Hacks.monitor_width = pair.first.to_i
      LVGL::Hacks.monitor_height = pair.last.to_i
    else
      LVGL::Hacks.monitor_width = 720
      LVGL::Hacks.monitor_height = 1280
    end

    # Get exclusive control of the framebuffer
    # By design we will not restore the console at exit.
    # We are assuming the target does not necessarily have a console attached to
    # the framebuffer, so this program has to be enough by itself.
    VTConsole.map_console(0)

    # XXX : here is the hang
    # Prepare LVGL
    LVGL::Hacks.init()

    # Start the animation core
    LVGL::FFI.lv_anim_core_init()

    # And switch to the desired theme
    LVGL::Hacks.theme_night(NIXOS_LIGHT_HUE)
  end

  # Runs the app, black boxes LVGL things.
  def self.main_loop()
    # Main loop
    while true
      LVGL::Hacks::LVTask.handle_tasks
      sleep(1.0/REFRESH_RATE)
      yield if block_given?
    end
  end

  def self.focus_group()
    LVGL::LVGroup.from_pointer(
      LVGL::FFI.lvgui_get_focus_group
    )
  end

  def self.focus_ring_disable()
    LVGL::FFI.lvgui_focus_ring_disable()
  end

  module Styles
    def self.debug(color)
      LVGL::LVStyle::STYLE_PLAIN.dup.tap do |style|
        style.body_main_color = color
        style.body_grad_color = color
      end
    end
  end

  # Wraps an LVGL widget.
  class Widget
    def initialize(widget)
      @widget = widget
    end
    def method_missing(*args)
      @widget.send(*args)
    end

    # Needed to make respond_to? work.
    def lv_obj_pointer()
      @widget.lv_obj_pointer
    end
  end

  # Used mainly to create an intangible object that the focus ring can default
  # on so it doesn't focus anything by default.
  class Dummy < Widget
    def initialize(parent)
      super(LVGL::LVObject.new(parent))
      set_width(0)
      set_height(0)
      set_style(LVGL::LVStyle::STYLE_TRANSP)
    end
  end

  # Horizontal separator between elements
  class HorizontalSeparator < Widget
    def initialize(parent)
      super(LVGL::LVObject.new(parent))
      set_width(parent.get_width_fit())
      set_height(1)

      LVGL::LVStyle::STYLE_PLAIN.dup().tap do |style|
        style.body_main_color = 0x99BBBBBB
        style.body_grad_color = style.body_main_color
        style.body_border_width = 0
        set_style(style)
      end
    end
  end

  class Button < Widget
    def initialize(parent)
      super(LVGL::LVButton.new(parent))
      set_layout(LVGL::LAYOUT::COL_M)
      set_ink_in_time(200)
      set_ink_wait_time(100)
      set_ink_out_time(500)
      set_fit2(LVGL::FIT::FILL, LVGL::FIT::TIGHT)
      @label = LVGL::LVLabel.new(self)
    end

    def set_label(label)
      @label.set_text(label)
    end
  end

  # Common pattern for a "back button".
  # Handles its presentation, and handles its behaviour.
  class BackButton < Button
    # +parent+: Parent object
    # +location+: An instance on which `present` can be called.
    def initialize(parent, location)
      @holder = LVGL::LVContainer.new(parent)
      @holder.set_fit2(LVGL::FIT::FILL, LVGL::FIT::TIGHT)
      @holder.set_style(LVGL::CONT_STYLE::MAIN, LVGL::LVStyle::STYLE_TRANSP.dup)
      style = @holder.get_style(LVGL::CONT_STYLE::MAIN)
      style.body_padding_top = 0
      style.body_padding_left = 0
      style.body_padding_right = 0
      style.body_padding_bottom = 0

      super(@holder)

      @location = location
      set_label("#{LVGL::Symbols::LEFT}  Back")
      set_fit2(LVGL::FIT::NONE, LVGL::FIT::TIGHT)
      set_width(@holder.get_width / 2)
      set_x(0)

      self.event_handler = ->(event) do
        case event
        when LVGL::EVENT::CLICKED
          location.present()
        end
      end
    end
  end

  # Implements a clock as a wrapped LVLabel.
  class Clock < Widget
    def initialize(parent)
      super(LVGL::LVLabel.new(parent))
      set_align(LVGL::LABEL_ALIGN::LEFT)
      set_long_mode(LVGL::LABEL_LONG::CROP)

      # Update the text once
      update_clock

      # Then register a task to update regularly.
      @task = LVGL::Hacks::LVTask.create_task(250, LVGL::TASK_PRIO::MID, ->() do
        update_clock
      end)
    end

    def update_clock()
      now = Time.now
      set_text([
        :hour,
        :min,
        :sec,
      ].map{|fn| now.send(fn).to_s.rjust(2, "0") }.join(":"))
    end
  end

  # Implements a battery widget as a wrapped LVLabel.
  class Battery < Widget
    def initialize(parent)
      super(LVGL::LVLabel.new(parent))
      set_align(LVGL::LABEL_ALIGN::RIGHT)
      set_long_mode(LVGL::LABEL_LONG::CROP)

      @battery = HAL::Battery.main_battery

      # Update the text once
      update_text

      # Then register a task to update regularly.
      @task = LVGL::Hacks::LVTask.create_task(1000 * 15, LVGL::TASK_PRIO::LOW, ->() do
        update_text
      end)
    end

    def update_text()
      if @battery
        symbol =
          if @battery.charging? then
            LVGL::Symbols::CHARGE
          elsif @battery.percent == "unknown"
            ""
          elsif @battery.percent > 95
            LVGL::Symbols::BATTERY_FULL
          elsif @battery.percent > 75
            LVGL::Symbols::BATTERY_3
          elsif @battery.percent > 45
            LVGL::Symbols::BATTERY_2
          elsif @battery.percent > 10
            LVGL::Symbols::BATTERY_1
          else
            LVGL::Symbols::BATTERY_EMPTY
          end

        set_text("#{symbol} #{@battery.percent}%")
      else
        set_text("")
      end
    end
  end

  # Empty invisible widget
  class Screen < Widget
    def initialize()
      super(LVGL::LVContainer.new())
      set_layout(LVGL::LAYOUT::COL_M)

      style = get_style(LVGL::CONT_STYLE::MAIN).dup
      set_style(LVGL::CONT_STYLE::MAIN, style)
      style.body_padding_top = 0
      style.body_padding_left = 0
      style.body_padding_right = 0
      style.body_padding_bottom = 0
      style.body_padding_inner = 0
    end
  end

  # Scrolling page.
  class Page < Widget
    def initialize(parent)
      @parent = parent
      # A "holder" widget to work around idiosyncracies of pages.
      @holder = LVGL::LVContainer.new(parent)
      @holder.set_fit2(LVGL::FIT::FILL, LVGL::FIT::NONE)
      @holder.set_style(LVGL::CONT_STYLE::MAIN, LVGL::LVStyle::STYLE_TRANSP.dup)

      # The actual widget we interact with
      super(LVGL::LVPage.new(@holder))
      style = LVGL::LVStyle::STYLE_TRANSP.dup
      # Padding to zero in the actual scrolling widget makes the scrollbar visible
      style.body_padding_left = 0
      style.body_padding_right = 0

      set_style(LVGL::PAGE_STYLE::BG, style)
      set_style(LVGL::PAGE_STYLE::SCRL, style)
      set_fit2(LVGL::FIT::FILL, LVGL::FIT::NONE)

      # Make this scroll
      set_scrl_layout(LVGL::LAYOUT::COL_M)

      refresh
    end

    # Call this function when the position of the Page is changed.
    # Mainly, this would be after filling the toolbar.
    def refresh()
      # Filling the parent that is at the root of the screen is apparently broken :/.
      @holder.set_height(@parent.get_height_fit - @holder.get_y)
      set_height(@holder.get_height - get_y)
    end
  end

  # A container, with a new name
  class Toolbar < Widget
    def initialize(parent)
      super(LVGL::LVContainer.new(parent))
      set_height(0)
      set_fit2(LVGL::FIT::FILL, LVGL::FIT::TIGHT)

      set_style(LVGL::CONT_STYLE::MAIN, LVGL::LVStyle::STYLE_TRANSP.dup)
      style = get_style(LVGL::CONT_STYLE::MAIN)
      style.body_padding_top = 0
      style.body_padding_bottom = 0
    end
  end

  # Widget implementing the whole header
  class Header < Widget
    def initialize(parent)
      super(LVGL::LVContainer.new(parent))

      header_style = get_style(LVGL::CONT_STYLE::MAIN).dup
      set_style(LVGL::CONT_STYLE::MAIN, header_style)
      header_style.glass = 1
      header_style.body_radius = 0
      header_style.body_opa = 255 * 0.6

      set_fit2(LVGL::FIT::FILL, LVGL::FIT::TIGHT)
      set_layout(LVGL::LAYOUT::PRETTY)

      # Split 50/50
      child_width = (
        get_width -
        header_style.body_padding_left -
        header_style.body_padding_right -
        header_style.body_padding_inner*2
      ) / 2

      # [00:00                           ]
      @clock = Clock.new(self)
      @clock.set_width(child_width)

      # [                             69%]
      @battery = Battery.new(self)
      @battery.set_width(child_width)
    end
  end
end
