# A standalone (no C++ implementation) G-code filter, to control cooling of the print.
# The G-code is processed per layer. Once a layer is collected, fan start / stop commands are edited
# and the print is modified to stretch over a minimum layer time.

package Slic3r::GCode::CoolingBuffer;
use Moo;

has 'config'    => (is => 'ro', required => 1);  # Slic3r::Config::Print
has 'gcodegen'  => (is => 'ro', required => 1);  # Slic3r::GCode C++ instance
has 'gcode'     => (is => 'rw', default => sub {""}); # Cache of a G-code snippet emitted for a single layer.
has 'elapsed_time' => (is => 'rw', default => sub {0});
has 'layer_id'  => (is => 'rw');
has 'last_z'    => (is => 'rw', default => sub { {} });  # obj_id => z (basically a 'last seen' table)
has 'min_print_speed' => (is => 'lazy');

sub _build_min_print_speed {
    my $self = shift;
    return 60 * $self->config->min_print_speed;
}

sub append {
    my $self = shift;
    my ($gcode, $obj_id, $layer_id, $print_z) = @_;
    
    my $return = "";
    if (exists $self->last_z->{$obj_id} && $self->last_z->{$obj_id} != $print_z) {
        # A layer was finished, Z of the object's layer changed. Process the layer.
        $return = $self->flush;
    }
    
    $self->layer_id($layer_id);
    $self->last_z->{$obj_id} = $print_z;
    $self->gcode($self->gcode . $gcode);
    #FIXME Vojtech: This is a very rough estimate of the print time, 
    # not taking into account the acceleration profiles generated by the printer firmware.
    $self->elapsed_time($self->elapsed_time + $self->gcodegen->elapsed_time);
    $self->gcodegen->set_elapsed_time(0);
    
    return $return;
}

sub flush {
    my $self = shift;
    
    my $gcode = $self->gcode;
    my $elapsed = $self->elapsed_time;
    $self->gcode("");
    $self->elapsed_time(0);
    $self->last_z({});  # reset the whole table otherwise we would compute overlapping times
    
    my $fan_speed = $self->config->fan_always_on ? $self->config->min_fan_speed : 0;
    my $speed_factor = 1;
    if ($self->config->cooling) {
        Slic3r::debugf "Layer %d estimated printing time: %d seconds\n", $self->layer_id, $elapsed;
        if ($elapsed < $self->config->slowdown_below_layer_time) {
            # Layer time very short. Enable the fan to a full throttle and slow down the print
            # (stretch the layer print time to slowdown_below_layer_time).
            $fan_speed = $self->config->max_fan_speed;
            $speed_factor = $elapsed / $self->config->slowdown_below_layer_time;
        } elsif ($elapsed < $self->config->fan_below_layer_time) {
            # Layer time quite short. Enable the fan proportionally according to the current layer time.
            $fan_speed = $self->config->max_fan_speed - ($self->config->max_fan_speed - $self->config->min_fan_speed)
                * ($elapsed - $self->config->slowdown_below_layer_time)
                / ($self->config->fan_below_layer_time - $self->config->slowdown_below_layer_time); #/
        }
        Slic3r::debugf "  fan = %d%%, speed = %f%%\n", $fan_speed, $speed_factor * 100;
        
        if ($speed_factor < 1) {
            # Adjust feed rate of G1 commands marked with an _EXTRUDE_SET_SPEED
            # as long as they are not _WIPE moves (they cannot if they are _EXTRUDE_SET_SPEED)
            # and they are not preceded directly by _BRIDGE_FAN_START (do not adjust bridging speed).
            $gcode =~ s/^(?=.*?;_EXTRUDE_SET_SPEED)(?!.*?;_WIPE)(?<!;_BRIDGE_FAN_START\n)(G1\sF)(\d+(?:\.\d+)?)/
                my $new_speed = $2 * $speed_factor;
                $1 . sprintf("%.3f", $new_speed < $self->min_print_speed ? $self->min_print_speed : $new_speed)
                /gexm;
        }
    }
    $fan_speed = 0 if $self->layer_id < $self->config->disable_fan_first_layers;
    $gcode = $self->gcodegen->writer->set_fan($fan_speed) . $gcode;
    
    # bridge fan speed
    if (!$self->config->cooling || $self->config->bridge_fan_speed == 0 || $self->layer_id < $self->config->disable_fan_first_layers) {
        $gcode =~ s/^;_BRIDGE_FAN_(?:START|END)\n//gm;
    } else {
        $gcode =~ s/^;_BRIDGE_FAN_START\n/ $self->gcodegen->writer->set_fan($self->config->bridge_fan_speed, 1) /gmex;
        $gcode =~ s/^;_BRIDGE_FAN_END\n/ $self->gcodegen->writer->set_fan($fan_speed, 1) /gmex;
    }
    $gcode =~ s/;_WIPE//g;
    $gcode =~ s/;_EXTRUDE_SET_SPEED//g;
    
    return $gcode;
}

1;
