
use Statocles::Test;
BEGIN {
    my $git_version = ( split ' ', `git --version` )[-1];
    plan skip_all => 'Git not installed' unless $git_version;
    diag "Git version: $git_version";
    my $v = sprintf '%i.%03i', split /[.]/, $git_version;
    plan skip_all => 'Git 1.5 or higher required' unless $v >= 1.005;
};

use Statocles::Site::Git;
use Statocles::Theme;
use Statocles::Store;
use Statocles::App::Blog;
use File::Copy::Recursive qw( dircopy );

my $SHARE_DIR = path( __DIR__ )->parent->child( 'share' );

my @temp_args;
if ( $ENV{ NO_CLEANUP } ) {
    @temp_args = ( CLEANUP => 0 );
}

*_git_run = \&Statocles::Site::Git::_git_run;

subtest 'site writes application' => sub {
    my $tmpdir = tempdir( @temp_args );
    diag "TMP: " . $tmpdir if @temp_args;

    my ( $site, $workdir, $remotedir ) = site( $tmpdir );
    my $git = Git::Repository->new( work_tree => "$workdir" );
    my $remotegit = Git::Repository->new( work_tree => "$remotedir" );

    subtest 'build' => sub {
        $site->build;

        for my $page ( $site->app( 'blog' )->pages ) {
            subtest 'page content' => test_content( $workdir, $site, $page, build => $page->path );
        }
    };

    subtest 'deploy' => sub {
        # Changed/added files not in the build directory do not get added
        $workdir->child( 'NEWFILE' )->spew( 'test' );

        # Origin must be on a different branch in order for push to work
        _git_run( $remotegit, branch => 'safe' );
        _git_run( $remotegit, checkout => 'safe' );

        $site->deploy;

        is current_branch( $git ), 'master', 'deploy leaves us on the branch we came from';

        for my $page ( $site->app( 'blog' )->pages ) {
            ok !$workdir->child( $page->path )->exists, 'file is not in master branch';
        }

        _git_run( $git, checkout => $site->deploy_branch );

        my $log = $git->run( log => -u => -n => 1 );
        like $log, qr{Site update};
        unlike $log, qr{NEWFILE};

        for my $page ( $site->app( 'blog' )->pages ) {
            subtest 'page content' => test_content( $workdir, $site, $page, '.' => $page->path );
        }
        _git_run( $git, checkout => 'master' );

        subtest 'deploy performs git push' => sub {
            _git_run( $remotegit, checkout => 'gh-pages' );
            for my $page ( $site->app( 'blog' )->pages ) {
                subtest 'page content' => test_content( $remotedir, $site, $page, '.' => $page->path );
            }
        };
    };
};

done_testing;

sub site {
    my ( $tmpdir, %site_args ) = @_;

    my $workdir = $tmpdir->child( 'workdir' );
    $workdir->mkpath;
    my $remotedir = $tmpdir->child( 'remotedir' );
    $remotedir->mkpath;

    # Git before 1.6.4 does not allow directory as argument to "init"
    my $cwd = cwd;
    chdir $workdir;
    Git::Repository->run( "init" );
    chdir $cwd;

    chdir $remotedir;
    Git::Repository->run( "init" );
    chdir $cwd;

    my $remotegit = Git::Repository->new( work_tree => "$remotedir" );
    my $workgit = Git::Repository->new( work_tree => "$workdir" );
    _git_run( $workgit, remote => add => origin => "$remotedir" );

    # Set some config so Git knows who we are (and doesn't complain)
    for my $git ( $workgit, $remotegit ) {
        _git_run( $git, config => 'user.name' => 'Statocles Test User' );
        _git_run( $git, config => 'user.email' => 'statocles@example.com' );
    }

    # Copy the source into the repository, so we have something to commit
    dircopy( $SHARE_DIR->child( 'blog' )->stringify, $remotedir->child( 'blog' )->stringify )
        or die "Could not copy directory: $!";
    _git_run( $remotegit, add => 'blog' );
    _git_run( $remotegit, commit => -m => 'Initial commit' );
    _git_run( $workgit, pull => origin => 'master' );

    my $theme = Statocles::Theme->new(
        source_dir => $SHARE_DIR->child( 'theme' ),
    );

    my $blog = Statocles::App::Blog->new(
        source => Statocles::Store->new(
            path => $workdir->child( 'blog' ),
        ),
        url_root => '/blog',
        theme => $theme,
    );

    my $site = Statocles::Site::Git->new(
        title => 'Test Site',
        apps => { blog => $blog },
        build_store => Statocles::Store->new(
            path => $workdir->child( 'build' ),
        ),
        deploy_store => Statocles::Store->new(
            path => $workdir,
        ),
        deploy_branch => 'gh-pages',
        %site_args,
    );

    return ( $site, $workdir, $remotedir );
}

sub test_content {
    my ( $tmpdir, $site, $page, $dir, $file ) = @_;
    return sub {
        my $path = $tmpdir->child( $dir, $file );
        my $html = $path->slurp;
        eq_or_diff $html, $page->render( site => $site );

        like $html, qr{@{[$site->title]}}, 'page contains site title ' . $site->title;
        for my $nav ( @{ $site->nav->{main} } ) {
            my $title = $nav->{title};
            my $url = $nav->{href};
            like $html, qr{$title}, 'page contains nav title ' . $title;
            like $html, qr{$url}, 'page contains nav url ' . $url;
        }
    };
}

sub current_branch {
    my ( $git ) = @_;
    my @branches = map { s/^\*\s+//; $_ } grep { /^\*/ } $git->run( 'branch' );
    return $branches[0];
}

