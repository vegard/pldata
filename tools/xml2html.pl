use strict;
use warnings;

use XML::Simple;

my $areadir = shift || '../areas';

opendir (my $dh, $areadir) or die $!;
my @areanames = sort map { /^(.*)\.xml$/ } grep { /\.xml$/ } readdir $dh;
close $dh;

my %areas;
for my $areaname (@areanames) {
	printf STDERR "Reading %s\n", $areaname;

	my $area = XML::Simple->new->XMLin($areadir . '/' . $areaname . '.xml',
		KeyAttr => {
			exit => 'name',
			object => '+vnum',
			room => '+vnum',
		},
		ForceArray => ['exit', 'extradesc', 'object', 'room', 'roomecho'],
		SuppressEmpty => 1,
	);
	$areas{$areaname} = $area;
}

system('mkdir', '-p', 'html');

# Map scale
my $scale = 48;

# Sanity checks
check_vnums();
check_links();

# Read logs
my %room_authors;


# NOTE: Adds a one-way exit only!
sub add_exit {
	my $room_vnum = shift;
	my $dir = shift;
	my $exit_vnum = shift;

	my $room = get_room($room_vnum);
	$room->{exit} = {} unless exists $room->{exit};
	$room->{exit}->{$dir} = {
		vnum => $exit_vnum,
	};

	$room->{name} = sprintf "** %s", $room->{name};
}

sub add_twoway_exit {
	my $room1_vnum = shift;
	my $dir1 = shift;
	my $room2_vnum = shift;
	my $dir2 = opposite_direction($dir1);

	add_exit($room1_vnum, $dir1, $room2_vnum);
	add_exit($room2_vnum, $dir2, $room1_vnum);
}

sub delete_one_exit {
	my $room_vnum = shift;
	my $room = get_room($room_vnum);
	my $dir = shift;

	delete $room->{exit}->{$dir};
}

sub delete_exit {
	my $room_vnum = shift;
	my $room = get_room($room_vnum);
	my $dir = shift;

	my $exit = $room->{exit}->{$dir};
	my $room2 = get_room($exit->{vnum});
	my $dir2 = opposite_direction($dir);
	delete $room2->{exit}->{$dir2};
	delete $room->{exit}->{$dir};
}

sub delete_room {
	my $room_vnum = shift;
	my ($area, $room) = get_room($room_vnum);
	my $exits = $room->{exit};

	for my $prop (('desc', 'editdraft', 'editdraftcomments', 'editfirst', 'editfirstcomments', 'editsecond', 'editsecondcomments', 'editeds', 'editedscomments')) {
		next unless exists $room->{$prop};
		next unless length $room->{$prop} > 16;

		warn sprintf "Deleting room %d in %s with %s: %s", $room_vnum, $area, $prop, $room->{$prop};
	}

	# Remove exits
	for my $dir (keys %$exits) {
		my $exit = $exits->{$dir};
		my $room2 = get_room($exit->{vnum});
		my $dir2 = opposite_direction($dir);

		delete $room2->{exit}->{$dir2};
	}

	delete $areas{$area}->{room}->{$room_vnum};
}

sub move_exit {
	my $room = get_room(shift);
	my $old_dir = shift;
	my $new_dir = shift;

	# First room
	my $old_exit = $room->{exit}->{$old_dir};
	delete $room->{exit}->{$old_dir};

	$room->{exit}->{$new_dir} = $old_exit;
	$room->{name} = sprintf "** %s", $room->{name};

	# Second room
	my $room2 = get_room($old_exit->{vnum});
	my $old_dir2 = opposite_direction($old_dir);
	my $new_dir2 = opposite_direction($new_dir);

	my $old_exit2 = $room2->{exit}->{$old_dir2};
	delete $room2->{exit}->{$old_dir2};

	$room2->{exit}->{$new_dir2} = $old_exit2;
	$room2->{name} = sprintf "** %s", $room2->{name};
}

# Generate highlight graphics
{
	my $size = 64;
	my $thickness = 4;

	use GD;
	my $highlight = GD::Image->new($size, $size);
	my $transparent = $highlight->colorAllocate(255, 255, 255);
	my $black = $highlight->colorAllocate(0, 0, 0);

	$highlight->transparent($transparent);
	$highlight->setThickness($thickness);
	$highlight->setAntiAliased($black);

	$highlight->arc($size / 2, $size / 2, $size - $thickness - 1, $size - $thickness - 1, 0, 360, gdAntiAliased);

	open my $fd, '>', 'html/highlight.png' or die $!;
	binmode $fd;
	print $fd $highlight->png;
	close $fd;
}

# Generate CSS
{
	open my $fd, '>', 'html/default.css' or die $!;
	print $fd <<EOF;
body {
	font-family: arial, helvetica, sans-serif;
}

a {
	color: maroon;
	text-decoration: none;
}

a:visited {
	color: maroon;
}

a:hover {
	color: orange;
}

a:active {
	color: orange;
}

h1 {
	font-size: 120%;

	padding-bottom: 0.2em;
	border-bottom: 1px solid black;
	margin-bottom: 0.2em;
}

h2 {
	font-size: 140%;

	padding-bottom: 0.5em;
	border-bottom: 1px solid black;
	margin-bottom: 0.5em;
}

img {
	border: 1px dashed black;
	display: block;
}

.text {
	max-width: 40em;
	text-align: justify;
}

.map {
	margin-left: 1em;

	display: inlineblock;
	float: right;
	border: 1px solid black;
}

.map .highlight {
	height: 100%;
	width: 100%;

	display: table;
}

.map .highlight2 {
	display: table-cell;
	vertical-align: middle;
}

.map img {
	border: 0;
	margin: auto;
}
EOF
	close $fd;
}

# Generate HTML and graphics
for my $area_shortname (sort keys %areas) {
	my $area = $areas{$area_shortname};
	my $area_name = $area->{areadata}->{name};
	my $rooms = $area->{room};

	system('mkdir', '-p', (sprintf "html/%s", $area_shortname));

	map_area($area_shortname);

	for my $room_vnum (keys %$rooms) {
		my $room = $rooms->{$room_vnum};

		my $room_name = strip($room->{name} || '');
		my $room_description = strip($room->{desc} || '');
		my $extras = $room->{extradesc} || [];
		my $exits = $room->{exit} || {};
		my $echoes = $room->{roomecho} || [];

		my %authors;
		for my $account (keys %{$room_authors{$room_vnum}}) {
			if (exists $authors{$account}) {
				$authors{$account} += $room_authors{$room_vnum}->{$account};
			} else {
				$authors{$account} = $room_authors{$room_vnum}->{$account};
			}
		}

		open my $fd, '>', (sprintf "html/%s/%d.html", $area_shortname, $room_vnum) or die $!;
		printf $fd "%s\n", '<?xml version="1.0" encoding="UTF-8" ?>';
		printf $fd "%s\n", '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">';
		printf $fd "%s\n", '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">';
		printf $fd "<head>\n";
		printf $fd "<title>%s -- %s</title>\n", $area_name, $room_name;
		printf $fd "<link rel=\"stylesheet\" href=\"../default.css\" type=\"text/css\" />\n";
		printf $fd "<script language=\"JavaScript\" type=\"text/javascript\">\n";
		printf $fd "function keyDown(e) {\n";
		printf $fd "\tvar key;\n";
		printf $fd "\tif (window.event) {\n";
		printf $fd "\t\tkey = e.keyCode;\n";
		printf $fd "\t} else {\n";
		printf $fd "\t\tkey = e.which;\n";
		printf $fd "\t}\n";
		printf $fd "\n";
		printf $fd "\tvar ch = String.fromCharCode(key);\n";

		my %directions = (
			0 => 'down',
			1 => 'southwest',
			2 => 'south',
			3 => 'southeast',
			4 => 'west',
			5 => 'up',
			6 => 'east',
			7 => 'northwest',
			8 => 'north',
			9 => 'northeast',
		);

		for my $i (sort { $a <=> $b } keys %directions) {
			my $dir = $directions{$i};

			if (exists $exits->{$dir}) {
				my $exit_vnum = $exits->{$dir}->{vnum};
				my ($exit_area, $exit_room) = get_room($exit_vnum);
				next unless defined $exit_room;

				printf $fd "\tif (ch === \"%d\") {\n", $i;
				printf $fd "\t\tlocation.replace(\"../%s/%d.html\");\n", $exit_area, $exit_vnum;
				printf $fd "\t}\n";
			}
		}

		printf $fd "};\n";
		printf $fd "document.onkeydown = keyDown;\n";
		printf $fd "</script>\n";
		printf $fd "</head>\n";
		printf $fd "<body>\n";
		printf $fd "<div id=\"title\">\n";
		printf $fd "<h1>%s</h1>\n", $area_name;
		printf $fd "<h2>%s</h2>\n", $room_name;
		printf $fd "</div>\n";

		my $small_size = 320;
		printf $fd "<div class=\"map\" style=\"width: %dpx; height: %dpx; background-image: url(&quot;%d-%d.png&quot;); background-repeat: no-repeat; background-position: %dpx %dpx;\"><div class=\"highlight\"><div class=\"highlight2\"><img src=\"../highlight.png\" alt=\"Map position highlight\" /></div></div></div>\n",
			$small_size, $small_size,
			$room->{map_id}, $room->{normal_z},
			-($scale * $room->{normal_x} + $scale / 2 - $small_size / 2 + 4 * $room->{normal_z}),
			-($scale * $room->{normal_y} + $scale / 2 - $small_size / 2 + 4 * $room->{normal_z});

		printf $fd "<div class=\"text\"><p>\n";

		for my $line (split m/\n\n/, $room_description) {
			printf $fd "%s<br /><br />\n", $line;
		}

		printf $fd "</p></div>\n";

		if (keys %$exits) {
			printf $fd "<div id=\"exits\">\n";
			printf $fd "<p>Exits:</p>\n";
			printf $fd "<ul>\n";

			for my $exit_direction (sort keys %$exits) {
				my $exit_vnum = $exits->{$exit_direction}->{vnum};
				my ($exit_area, $exit_room) = get_room($exit_vnum);
				next unless defined $exit_room;

				printf $fd "<li><a href=\"../%s/%d.html\">%s</a> - %s</li>\n", $exit_area, $exit_vnum, ucfirst $exit_direction, strip($exit_room->{name} || '');
			}

			printf $fd "</ul>\n";
			printf $fd "</div>\n";
		}

		if (@$extras) {
			printf $fd "<div id=\"extradescriptions\">\n";
			printf $fd "<p>Extra descriptions:</p>\n";
			printf $fd "<ul>\n";

			for my $extra (@$extras) {
				printf $fd "<li>%s - %s</li>\n",
					(join ', ', split ' ', $extra->{keywords}), strip($extra->{desc} || '');
			}

			printf $fd "</ul>\n";
			printf $fd "</div>\n";
		}

		if (@$echoes) {
			printf $fd "<div id=\"echoes\">\n";
			printf $fd "<p>Echoes:</p>\n";
			printf $fd "<ul>\n";

			for my $echo (sort { $a->{chance} cmp $b->{chance} } @$echoes) {
				printf $fd "<li>%02d-%02d (%d%%) %s</li>\n",
					$echo->{after}, $echo->{before}, $echo->{chance},
					strip($echo->{desc});
			}

			printf $fd "</ul>\n";
			printf $fd "</div>\n";
		}

		my @edits = (
			{
				name => 'editdraft',
				title => 'Edit draft',
			},
			{
				name => 'editdraftcomments',
				title => 'Edit draft comments',
			},
			{
				name => 'editfirst',
				title => 'First edit draft',
			},
			{
				name => 'editfirstcomments',
				title => 'First edit draft comments',
			},
			{
				name => 'editsecond',
				title => 'Second edit draft',
			},
			{
				name => 'editsecondcomments',
				title => 'Second edit draft comments',
			},
			{
				name => 'editeds',
				title => 'Extra descriptions draft',
			},
			{
				name => 'editedscomments',
				title => 'Extra descriptions draft comments',
			},
		);

		for my $edit (@edits) {
			if (exists $room->{$edit->{name}}) {
				my $text = $room->{$edit->{name}};
				next if length $text == 0;

				printf $fd "<div class=\"text\"><h3>%s</h3><p>\n", $edit->{title};

				for my $line (split m/\n\n/, $text) {
					printf $fd "%s<br /><br />\n", $line;
				}

				printf $fd "</p></div>\n";
			}
		}

		if (scalar keys %authors) {
			printf $fd "<div id=\"authors\">\n";
			printf $fd "<p>Likely authors:</p>\n";
			printf $fd "<ul>\n";

			for my $account (sort { $authors{$b} <=> $authors{$a} } keys %authors) {
				printf $fd "<li>(%d) %s</li>\n", $authors{$account}, $account;
			}

			printf $fd "</ul>\n";
			printf $fd "</div>\n";
		}

		$room->{authors} = \%authors;

		printf $fd "</body>\n";
		printf $fd "</html>\n";
		close $fd;
	}
}

sub map_area {
	my $area_shortname = shift;
	my $area = $areas{$area_shortname};
	my $area_name = $area->{areadata}->{name};
	my $rooms = $area->{room};

	open my $fd, '>', (sprintf "html/%s/index.html", $area_shortname) or die $!;
	printf $fd "%s\n", '<?xml version="1.0" encoding="UTF-8" ?>';
	printf $fd "%s\n", '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">';
	printf $fd "%s\n", '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">';
	printf $fd "<head>\n";
	printf $fd "<title>%s</title>\n", $area_name;
	printf $fd "<link rel=\"stylesheet\" href=\"../default.css\" type=\"text/css\" />\n";
	printf $fd "</head>\n";
	printf $fd "<body>\n";
	printf $fd "<div id=\"title\"><h1>%s</h1></div>\n", $area_name;
	printf $fd "<div id=\"rooms\">\n";
	printf $fd "<p>Rooms:</p>\n";
	printf $fd "<ul>\n";

	for my $room_vnum (sort keys %$rooms) {
		my $room = $rooms->{$room_vnum};
		my $room_name = $room->{name} || '';

		printf $fd "<li><a href=\"../%s/%d.html\">#%d</a> - %s</li>\n", $area_shortname, $room_vnum, $room_vnum, strip($room_name);
	}

	printf $fd "</ul>\n";
	printf $fd "</div>\n";

	printf $fd "<div id=\"maps\">\n";

	# Create maps
	my %unmapped_rooms = map { $_ => undef } keys %$rooms;

	for (my $i = 0; keys %unmapped_rooms; ++$i) {
		my $unmapped_room = (keys %unmapped_rooms)[0];

		my $min_x = 0;
		my $min_y = 0;
		my $min_z = 0;
		my $max_x = 0;
		my $max_y = 0;
		my $max_z = 0;

		my @todo = ([$unmapped_room, 0, 0, 0]);
		my %map;
		my @map_rooms;

		while (@todo) {
			my ($room_vnum, $x, $y, $z) = @{shift @todo};
			delete $unmapped_rooms{$room_vnum} if exists $unmapped_rooms{$room_vnum};

			# Only find rooms in the same area
			next unless exists $rooms->{$room_vnum};
			my $room = $rooms->{$room_vnum};
			if ($room->{mapped}) {
				if ($room->{map_x} != $x || $room->{map_y} != $y || $room->{map_z} != $z) {
					warn "Room $room_vnum doesn't agree on its coordinates";
					printf STDERR "%d,%d,%d -- %d,%d,%d\n",
						$room->{map_x}, $room->{map_y}, $room->{map_z},
						$x, $y, $z;
					$room->{map_color} = 'orange';
				}
				next;
			}

			my $coords = sprintf "%d,%d,%d", $x, $y, $z;
			if (exists $map{$coords} && $map{$coords} != $room_vnum) {
				printf STDERR "%s: %s (%d vs. %d)\n", $area_name, $coords, $map{$coords}, $room_vnum;

				$room->{map_color} = 'red';
				$rooms->{$map{$coords}}->{map_color} = 'green';
			} else {
				$map{$coords} = $room_vnum;
			}

			$room->{mapped} = 1;
			$room->{map_x} = $x;
			$room->{map_y} = $y;
			$room->{map_z} = $z;
			push @map_rooms, $room_vnum;

			$min_x = $x if $x < $min_x;
			$max_x = $x if $x > $max_x;
			$min_y = $y if $y < $min_y;
			$max_y = $y if $y > $max_y;
			$min_z = $z if $z < $min_z;
			$max_z = $z if $z > $max_z;

			my %dir_sort_order = (
				north => 0,
				south => 0,
				east => 0,
				west => 0,
				northeast => 1,
				southeast => 1,
				northwest => 1,
				southwest => 1,
				up => 2,
				down => 2,
			);

			my $exits = $room->{exit} || {};
			for my $direction (sort { $dir_sort_order{$a} <=> $dir_sort_order{$b} } keys %$exits)
			{
				my $exit_vnum = $exits->{$direction}->{vnum};

				if ($direction eq 'north') {
					push @todo, [$exit_vnum, $x, $y - 1, $z];
				} elsif ($direction eq 'northeast') {
					push @todo, [$exit_vnum, $x + 1, $y - 1, $z];
				} elsif ($direction eq 'east') {
					push @todo, [$exit_vnum, $x + 1, $y, $z];
				} elsif ($direction eq 'southeast') {
					push @todo, [$exit_vnum, $x + 1, $y + 1, $z];
				} elsif ($direction eq 'south') {
					push @todo, [$exit_vnum, $x, $y + 1, $z];
				} elsif ($direction eq 'southwest') {
					push @todo, [$exit_vnum, $x - 1, $y + 1, $z];
				} elsif ($direction eq 'west') {
					push @todo, [$exit_vnum, $x - 1, $y, $z];
				} elsif ($direction eq 'northwest') {
					push @todo, [$exit_vnum, $x - 1, $y - 1, $z];
				} elsif ($direction eq 'up') {
					push @todo, [$exit_vnum, $x, $y, $z + 1];
				} elsif ($direction eq 'down') {
					push @todo, [$exit_vnum, $x, $y, $z - 1];
				} else {
					warn "Unknown direction $direction";
				}
			}
		}

		for my $room_vnum (@map_rooms) {
			my $room = $rooms->{$room_vnum};
			$room->{map_id} = $i;
			$room->{normal_x} = $room->{map_x} - $min_x;
			$room->{normal_y} = $room->{map_y} - $min_y;
			$room->{normal_z} = $room->{map_z} - $min_z;
		}

for my $floor ($min_z .. $max_z) {
my $floor_n = $floor - $min_z;

		# Make graphviz graph
		open my $gv_fd, '>', sprintf "html/%s/graph-%d-%d.dot", $area_shortname, $i, $floor_n or die $!;
		printf $gv_fd "graph g {\n";
		printf $gv_fd "\toverlap=false;\n";

		my %gv_exits;

		for my $room_vnum (grep { $rooms->{$_}->{map_z} == $floor } @map_rooms) {
			my $room = $rooms->{$room_vnum};
			my $name = $room->{name} || '';

			my $shape;
			if (exists $room->{exit}->{down}) {
				if (exists $room->{exit}->{up}) {
					$shape = 'diamond';
				} else {
					$shape = 'invtriangle';
				}
			} else {
				if (exists $room->{exit}->{up}) {
					$shape = 'triangle';
				} else {
					$shape = 'box';
				}
			}

#			if (exists $room->{map_free} && $room->{map_free} == 1) {
#				printf $gv_fd "\tr_%d [label=\"%s\",shape=circle];\n",
#					$room_vnum, $room_vnum;
#			} else {
				printf $gv_fd "\tr_%d [pos=\"%d,%d%s\",label=\"%s\",shape=%s,color=%s];\n",
					$room_vnum,
					96 * (2 + $room->{map_x} - $min_x),
					96 * (2 + $max_y - $room->{map_y}),
					exists $room->{map_color} ? "" : "",
					$room_vnum,
					$shape,
					exists $room->{map_color} ? $room->{map_color} : "black";
#			}

			my $exits = $room->{exit} || {};
			for my $direction (keys %$exits) {
				my $exit_vnum = $exits->{$direction}->{vnum};

				if (exists $rooms->{$exit_vnum}
					&& grep { $_ == $exit_vnum
					&& $rooms->{$_}->{map_z} == $floor } @map_rooms)
				{
					my $exit_room = $rooms->{$exit_vnum};

					my $key = join '.', sort ($room_vnum, $exit_vnum);
					next if exists $gv_exits{$key};
					$gv_exits{$key} = undef;

					printf $gv_fd "\tr_%d -- r_%d [label=\"%s\"];\n",
						$room_vnum, $exit_vnum, twoway_direction_abbrev($direction);
				}
			}
		}

		printf $gv_fd "};";
		close $gv_fd;


		printf $fd "<p>Map %d (Floor %d)</p>\n", $i + 1, $floor_n + 1;

		printf $fd "<img src=\"%d-%d.png\" usemap=\"#%d-%d\" />\n",
			$i, $floor_n, $i, $floor_n;
		printf $fd "<map name=\"%d-%d\">\n", $i, $floor_n;

		use GD;
		my $img = GD::Image->new($scale * (1 + $max_x - $min_x) + 4 * ($max_z - $min_z),
			$scale * (1 + $max_y - $min_y) + 4 * ($max_z - $min_z));

		my $transparent = $img->colorAllocate(255, 255, 255);
		my $white = $img->colorAllocate(255, 255, 255);
		my $black = $img->colorAllocate(0, 0, 0);
		my $red = $img->colorAllocate(255, 192, 192);
		my $dark_red = $img->colorAllocate(255, 128, 128);
		my $green = $img->colorAllocate(192, 255, 192);
		my $dark_green = $img->colorAllocate(128, 255, 128);
		my $blue = $img->colorAllocate(192, 192, 255);

		# One shade of grey per floor
		my @grey = map {
			my $min = 128;
			my $max = 240;
			my $c = ($_ - $min_z) / ($max_z - $min_z + 1) * ($max - $min) + $min;
			$img->colorAllocate($c, $c, $c)
		} ($min_z .. $floor);

		my $orange = $img->colorAllocate(255, 255, 128);

		$img->fill(0, 0, $transparent);
		$img->transparent($transparent);

		for my $z ($min_z .. $floor) {
			my $zoff = 4 * ($z - $min_z);

			# Draw exits
	if ($z == $floor) {
			for my $room_vnum (grep { $rooms->{$_}->{map_z} == $z } @map_rooms) {
				my $room = $rooms->{$room_vnum};
				my $name = $room->{name} || '';

				my $x = $room->{map_x} - $min_x;
				my $y = $room->{map_y} - $min_y;

				my $exits = $room->{exit} || {};
				for my $direction (keys %$exits) {
					my $exit_vnum = $exits->{$direction}->{vnum};

					# XXX: Inefficient?
					if (exists $rooms->{$exit_vnum} && grep { $_ == $exit_vnum } @map_rooms) {
						my $exit_room = $rooms->{$exit_vnum};
						my $exit_x = $exit_room->{map_x} - $min_x;
						my $exit_y = $exit_room->{map_y} - $min_y;

						$img->line($scale * ($x + 0.5) + $zoff, $scale * ($y + 0.5) + $zoff,
							$scale * ($exit_x + 0.5) + $zoff, $scale * ($exit_y + 0.5) + $zoff,
							$black);
					} else {
						my $poly = GD::Polygon->new;

						my $xc = $scale * ($x + 0.5) + $zoff;
						my $yc = $scale * ($y + 0.5) + $zoff;

						if ($direction eq 'north') {
							$poly->addPt($xc - 4, $yc);
							$poly->addPt($xc + 4, $yc);
							$poly->addPt($xc + 4, $yc - $scale + 4);
							$poly->addPt($xc - 4, $yc - $scale + 4);
						} elsif ($direction eq 'east') {
							$poly->addPt($xc, $yc - 4);
							$poly->addPt($xc, $yc + 4);
							$poly->addPt($xc + $scale - 4, $yc + 4);
							$poly->addPt($xc + $scale - 4, $yc - 4);
						} elsif ($direction eq 'south') {
							$poly->addPt($xc - 4, $yc);
							$poly->addPt($xc + 4, $yc);
							$poly->addPt($xc + 4, $yc + $scale - 4);
							$poly->addPt($xc - 4, $yc + $scale - 4);
						} elsif ($direction eq 'west') {
							$poly->addPt($xc, $yc - 4);
							$poly->addPt($xc, $yc + 4);
							$poly->addPt($xc - $scale + 4, $yc + 4);
							$poly->addPt($xc - $scale + 4, $yc - 4);
						} elsif ($direction eq 'up') {
						} elsif ($direction eq 'down') {
						} else {
							printf "%s: unhandled external exit in direction: %s\n", $area_name, $direction;
						}

						$img->filledPolygon($poly, $blue);
						$img->openPolygon($poly, $black);
					}
				}
			}
	}

			# Draw rooms
			for my $room_vnum (grep { $rooms->{$_}->{map_z} == $z } @map_rooms) {
				my $room = $rooms->{$room_vnum};
				my $name = $room->{name} || '';
				my $x = $room->{map_x} - $min_x;
				my $y = $room->{map_y} - $min_y;

				my $xa = $scale * $x + 4 + $zoff;
				my $ya = $scale * $y + 4 + $zoff;
				my $xb = $scale * ($x + 1) - 4 + $zoff;
				my $yb = $scale * ($y + 1) - 4 + $zoff;

				{
					my $poly = GD::Polygon->new;
					$poly->addPt($xa + 8, $ya);
					$poly->addPt($xb - 8, $ya);

					$poly->addPt($xb - 8, $ya);
					$poly->addPt($xb, $ya + 8);

					$poly->addPt($xb, $ya + 8);
					$poly->addPt($xb, $yb - 8);

					$poly->addPt($xb, $yb - 8);
					$poly->addPt($xb - 8, $yb);

					$poly->addPt($xa + 8, $yb);
					$poly->addPt($xa, $yb - 8);

					$poly->addPt($xa, $ya + 8);

					if ($z == $floor) {
						if (room_is_empty($room)) {
							# Very short descriptions indicate an unwritten room
							$img->filledPolygon($poly, $red);
						} elsif (room_is_draft($room)) {
							# Unedited drafts
							$img->filledPolygon($poly, $orange);
						} else {
							$img->filledPolygon($poly, $green);
						}
						$img->openPolygon($poly, $black);
					} else {
						$img->filledPolygon($poly, $grey[$z - $min_z]);
					}
				}

				if ($z == $floor) {
					$img->string(gdSmallFont,
						$scale * $x + 8 + $zoff, $scale * $y + 18 + $zoff,
						$room_vnum, $black);

					my $exits = $room->{exit} || {};
					if (exists $exits->{up}) {
						my $poly = GD::Polygon->new;
						$poly->addPt($scale * ($x + 0.5) + $zoff, $scale * $y + 4 + $zoff);
						$poly->addPt($scale * ($x + 0.5) - 8 + $zoff, $scale * $y + 12 + $zoff);
						$poly->addPt($scale * ($x + 0.5) + 8 + $zoff, $scale * $y + 12 + $zoff);

						$img->filledPolygon($poly, $dark_red);
						$img->openPolygon($poly, $black);
					}
					if (exists $exits->{down}) {
						my $poly = GD::Polygon->new;
						$poly->addPt($scale * ($x + 0.5) + $zoff, $scale * ($y + 1) - 4 + $zoff);
						$poly->addPt($scale * ($x + 0.5) - 8 + $zoff, $scale * ($y + 1) - 12 + $zoff);
						$poly->addPt($scale * ($x + 0.5) + 8 + $zoff, $scale * ($y + 1) - 12 + $zoff);

						$img->filledPolygon($poly, $dark_red);
						$img->openPolygon($poly, $black);
					}

					printf $fd "<area shape=\"rect\" coords=\"%d,%d,%d,%d\" href=\"../%s/%d.html\"/>\n",
						$xa, $ya, $xb, $yb, $area_shortname, $room_vnum;
				}
			}
		}

		printf $fd "</map>\n";

		open my $img_fd, '>', (sprintf "html/%s/%d-%d.png", $area_shortname, $i, $floor_n) or die $!;
		binmode $img_fd;
		print $img_fd $img->png;
		close $img_fd;
}
	}

	printf $fd "</div>\n";
	printf $fd "</body>\n";
	printf $fd "</html>\n";
	close $fd;
}

open my $fd, '>', "html/index.html" or die $!;
printf $fd "%s\n", '<?xml version="1.0" encoding="UTF-8" ?>';
printf $fd "%s\n", '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">';
printf $fd "%s\n", '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">';
printf $fd "<head>\n";
printf $fd "<title>Index</title>\n";
printf $fd "<link rel=\"stylesheet\" href=\"default.css\" type=\"text/css\" />\n";
printf $fd "</head>\n";
printf $fd "<body>\n";
printf $fd "<div id=\"title\"><h1>Index</h1></div>\n";
printf $fd "<div id=\"areas\">\n";
printf $fd "<p>Areas:</p>\n";
printf $fd "<ul>\n";

for my $area_shortname (sort { $areas{$a}->{areadata}->{name} cmp $areas{$b}->{areadata}->{name} } keys %areas) {
	my $area = $areas{$area_shortname};
	my $area_name = $area->{areadata}->{name};
	my $rooms = $area->{room};

	printf $fd "<li>\n";
	printf $fd "<a href=\"%s/index.html\">%s</a>\n", $area_shortname, $area_name;


	# Number-of-rooms statistics
	my $nr_empty = 0;
	my $nr_unfinished = 0;
	my $nr_finished = 0;

	for my $room_vnum (keys %$rooms) {
		my $room = $rooms->{$room_vnum};

		if (room_is_empty($room)) {
			++$nr_empty;
		} elsif (room_is_draft($room)) {
			++$nr_unfinished;
		} else {
			++$nr_finished;
		}
	}

	printf $fd "<ul>\n";
	printf $fd "<li>%d empty rooms</li>\n", $nr_empty;
	printf $fd "<li>%d drafted rooms</li>\n", $nr_unfinished;
	printf $fd "<li>%d finished rooms</li>\n", $nr_finished;


	# Author statistics
	my %authors;
	my $total_score = 0;

	for my $room_vnum (keys %$rooms) {
		my $room = $rooms->{$room_vnum};
		my $room_authors = $room->{authors};

		for my $author (keys %$room_authors) {
			$authors{$author} = 0 unless exists $authors{$author};
			$authors{$author} += $room_authors->{$author};
			$total_score += $room_authors->{$author};
		}
	}

	my @top_authors = sort { $authors{$b} <=> $authors{$a} } keys %authors;
	if (@top_authors) {
		my $top_contribution = $authors{$top_authors[0]};
		@top_authors = grep { $authors{$_} > $top_contribution / 3 } @top_authors;

		printf $fd "<li>Possible authors:\n";
		printf $fd "<ul>\n";

		for my $author (@top_authors) {
			printf $fd "<li>%s (%.2f%%)</li>\n",
				$author, 100 * $authors{$author} / $total_score;
		}

		printf $fd "</ul>\n";
		printf $fd "</li>\n";
	}


	printf $fd "</ul>\n";
	printf $fd "</li>\n";
}

printf $fd "</ul>\n";
printf $fd "</div>\n";
printf $fd "</body>\n";
printf $fd "</html>\n";
close $fd;

sub read_log {
	my $filename = shift;

	open my $log_fd, '<', $filename || die $!;
	chomp(my @log = <$log_fd>);
	close $log_fd;

	for my $line (@log) {
		my $score = 0;
		my $room_vnum;
		my $account;

		if ($line =~ m/^.*: \[(.*)\] (.*): .*\(redit\)$/) {
			$room_vnum = $1;
			$account = $2;
			$score = 1;
		} elsif ($line =~ m/^.*: \[(.*)\] (.*): .*'desc'$/) {
			$room_vnum = $1;
			$account = $2;
			$score = 3;
		} else {
			next;
		}

		$room_authors{$room_vnum} = {} unless exists $room_authors{$room_vnum};

		my $authors = $room_authors{$room_vnum};
		$authors->{$account} = 0 unless exists $authors->{$account};
		$authors->{$account} += $score;
	}
}

sub get_room {
	my $vnum = shift;

	for my $area_shortname (keys %areas) {
		my $area = $areas{$area_shortname};

		return ($area_shortname, $area->{room}->{$vnum}) if exists $area->{room}->{$vnum};
	}

	return undef;
}

sub strip {
	my $string = shift;
	use Carp qw(cluck);
	cluck unless defined $string;
	$string =~ s/`.//g;
	return $string;
}

# Check that there are no duplicate vnums in two different areas
sub check_vnums {
	my %vnums;

	for my $area_shortname (sort keys %areas) {
		my $area = $areas{$area_shortname};
		my $rooms = $area->{room};

		for my $room_vnum (keys %$rooms) {
			$vnums{$room_vnum} = [] unless exists $vnums{$room_vnum};
			push @{$vnums{$room_vnum}}, $area_shortname;
		}
	}

	my @dup_vnums = sort grep { @{$vnums{$_}} > 1 } keys %vnums;

	if (@dup_vnums) {
		printf "Found %d duplicate vnums:\n", scalar @dup_vnums;
	}

	for my $vnum (@dup_vnums) {
		my @results;

		my $vnum_areas = $vnums{$vnum};
		for my $area_shortname (@$vnum_areas) {
			my $area = $areas{$area_shortname};
			my $room = $area->{room}->{$vnum};

			push @results, sprintf "%s (%d)", $area_shortname, length $room->{desc};
		}

		printf "#%d: %s\n", $vnum, (join', ', @results);
	}
}

sub twoway_direction_abbrev {
	my $dir = shift;

	if ($dir eq 'north' || $dir eq 'south') {
		return 'n/s';
	} elsif ($dir eq 'east' || $dir eq 'west') {
		return 'e/w';
	} elsif ($dir eq 'northeast' || $dir eq 'southwest') {
		return 'ne/sw';
	} elsif ($dir eq 'northwest' || $dir eq 'southeast') {
		return 'nw/se';
	} elsif ($dir eq 'up' || $dir eq 'down') {
		return 'u/d';
	}

	die "Unknown direction";
}

sub opposite_direction {
	my $dir = shift;

	if ($dir eq 'north') {
		return 'south';
	} elsif ($dir eq 'northeast') {
		return 'southwest';
	} elsif ($dir eq 'east') {
		return 'west';
	} elsif ($dir eq 'southeast') {
		return 'northwest';
	} elsif ($dir eq 'south') {
		return 'north';
	} elsif ($dir eq 'southwest') {
		return 'northeast';
	} elsif ($dir eq 'west') {
		return 'east';
	} elsif ($dir eq 'northwest') {
		return 'southeast';
	} elsif ($dir eq 'up') {
		return 'down';
	} elsif ($dir eq 'down') {
		return 'up';
	}

	die "Unknown direction";
}

# Check that all exits are two-way
sub check_links {
	for my $area_shortname (sort keys %areas) {
		my $area = $areas{$area_shortname};
		my $rooms = $area->{room};

		for my $room_vnum (keys %$rooms) {
			my $room = $rooms->{$room_vnum};
			my $exits = $room->{exit} || {};

			for my $direction (keys %$exits) {
				my $exit_vnum = $exits->{$direction}->{vnum};
				my ($exit_area, $exit_room) = get_room($exit_vnum);

				if (!defined $exit_room) {
					#warn sprintf "Exit %s in room %d (%s) leads to an unknown room",
					#	$direction, $room_vnum, $area_shortname;
					next;
				}

				my $exit_room_exits = $exit_room->{exit} || {};
				my $opposite_dir = opposite_direction($direction);

				if (!exists $exit_room_exits->{$opposite_dir}) {
					warn sprintf "Exit %s in room %d (%s) has no return link from room %d (%s)",
						$direction, $room_vnum, $area_shortname, $exit_vnum, $exit_area;
					next;
				}

				if ($exit_room_exits->{$opposite_dir}->{vnum} != $room_vnum) {
					warn sprintf "Exit %s in room %d (%s) doesn't return to the same room, but to room %d (%s)",
						$direction, $room_vnum, $area_shortname, $exit_vnum, $exit_area;
					next;
				}
			}
		}
	}
}

sub room_is_empty {
	my $room = shift;

	# If all of these properties are shorter than three lines, we consider it empty
	for my $prop (('desc', 'editdraft', 'editdraftcomments', 'editfirst', 'editfirstcomments', 'editsecond', 'editsecondcomments', 'editeds', 'editedscomments')) {
		return 0 if exists $room->{$prop} && length $room->{$prop} > 2 * 80;
	}

	return 1;
}

sub room_is_draft {
	my $room = shift;

	return 1 if defined $room->{name} && $room->{name} =~ m/(draft|\*)/i;
	return defined $room->{desc} && length $room->{desc} < 3 * 80;
}
