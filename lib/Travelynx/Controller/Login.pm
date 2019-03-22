package Travelynx::Controller::Login;
use Mojo::Base 'Mojolicious::Controller';

use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);
use Encode qw(decode encode);
use Email::Sender::Simple qw(try_to_sendmail);
use Email::Simple;
use UUID::Tiny qw(:std);

sub hash_password {
	my ($password) = @_;
	my @salt_bytes = map { int( rand(255) ) + 1 } ( 1 .. 16 );
	my $salt = en_base64( pack( 'C[16]', @salt_bytes ) );

	return bcrypt( $password, '$2a$12$' . $salt );
}

sub make_token {
	return create_uuid_as_string(UUID_V4);
}

sub login_form {
	my ($self) = @_;
	$self->render('login');
}

sub do_login {
	my ($self)   = @_;
	my $user     = $self->req->param('user');
	my $password = $self->req->param('password');

	# Keep cookies for 6 months
	$self->session( expiration => 60 * 60 * 24 * 180 );

	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'login',
			invalid => 'csrf',
		);
	}
	else {
		if ( $self->authenticate( $user, $password ) ) {
			$self->redirect_to( $self->req->param('redirect_to') // '/' );
		}
		else {
			my $data = $self->get_user_password($user);
			if ( $data and $data->{status} == 0 ) {
				$self->render( 'login', invalid => 'confirmation' );
			}
			else {
				$self->render( 'login', invalid => 'credentials' );
			}
		}
	}
}

sub registration_form {
	my ($self) = @_;
	$self->render('register');
}

sub register {
	my ($self)    = @_;
	my $user      = $self->req->param('user');
	my $email     = $self->req->param('email');
	my $password  = $self->req->param('password');
	my $password2 = $self->req->param('password2');
	my $ip        = $self->req->headers->header('X-Forwarded-For');
	my $ua        = $self->req->headers->user_agent;
	my $date = DateTime->now( time_zone => 'Europe/Berlin' )
	  ->strftime('%d.%m.%Y %H:%M:%S %z');

	# In case Mojolicious is not running behind a reverse proxy
	$ip
	  //= sprintf( '%s:%s', $self->tx->remote_address, $self->tx->remote_port );

	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'register',
			invalid => 'csrf',
		);
		return;
	}

	if ( not length($user) ) {
		$self->render( 'register', invalid => 'user_empty' );
		return;
	}

	if ( not length($email) ) {
		$self->render( 'register', invalid => 'mail_empty' );
		return;
	}

	if ( $user !~ m{ ^ [0-9a-zA-Z_-]+ $ }x ) {
		$self->render( 'register', invalid => 'user_format' );
		return;
	}

	if ( $self->check_if_user_name_exists($user) ) {
		$self->render( 'register', invalid => 'user_collision' );
		return;
	}

	if ( $self->check_if_mail_is_blacklisted($email) ) {
		$self->render( 'register', invalid => 'mail_blacklisted' );
		return;
	}

	if ( $password ne $password2 ) {
		$self->render( 'register', invalid => 'password_notequal' );
		return;
	}

	if ( length($password) < 8 ) {
		$self->render( 'register', invalid => 'password_short' );
		return;
	}

	my $token   = make_token();
	my $pw_hash = hash_password($password);
	$self->app->dbh->begin_work;
	my $user_id     = $self->add_user( $user, $email, $token, $pw_hash );
	my $reg_url     = $self->url_for('reg')->to_abs->scheme('https');
	my $imprint_url = $self->url_for('impressum')->to_abs->scheme('https');

	my $body = "Hallo, ${user}!\n\n";
	$body .= "Mit deiner E-Mail-Adresse (${email}) wurde ein Account bei\n";
	$body .= "travelynx angelegt.\n\n";
	$body
	  .= "Falls die Registrierung von dir ausging, kannst du den Account unter\n";
	$body .= "${reg_url}/${user_id}/${token}\n";
	$body .= "freischalten.\n\n";
	$body
	  .= "Falls nicht, ignoriere diese Mail bitte. Nach etwa 48 Stunden wird deine\n";
	$body
	  .= "Mail-Adresse erneut zur Registrierung freigeschaltet. Falls auch diese fehlschlägt,\n";
	$body
	  .= "werden wir sie dauerhaft sperren und keine Mails mehr dorthin schicken.\n\n";
	$body .= "Daten zur Registrierung:\n";
	$body .= " * Datum: ${date}\n";
	$body .= " * Verwendete IP: ${ip}\n";
	$body .= " * Verwendeter Browser gemäß User Agent: ${ua}\n\n\n";
	$body .= "Impressum: ${imprint_url}\n";

	my $reg_mail = Email::Simple->create(
		header => [
			To             => $email,
			From           => 'Travelynx <travelynx@finalrewind.org>',
			Subject        => 'Registrierung bei travelynx',
			'Content-Type' => 'text/plain; charset=UTF-8',
		],
		body => encode( 'utf-8', $body ),
	);

	my $success = try_to_sendmail($reg_mail);
	if ($success) {
		$self->app->dbh->commit;
		$self->render( 'login', from => 'register' );
	}
	else {
		$self->app->dbh->rollback;
		$self->render( 'register', invalid => 'sendmail' );
	}
}

sub verify {
	my ($self) = @_;

	my $id    = $self->stash('id');
	my $token = $self->stash('token');

	my @db_user = $self->get_user_token($id);

	if ( not @db_user ) {
		$self->render( 'register', invalid => 'token' );
		return;
	}

	my ( $db_name, $db_status, $db_token ) = @db_user;

	if ( not $db_name or $token ne $db_token or $db_status != 0 ) {
		$self->render( 'register', invalid => 'token' );
		return;
	}
	$self->app->set_status_query->execute( 1, $id );
	$self->render( 'login', from => 'verification' );
}

sub delete {
	my ($self) = @_;
	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render( 'account', invalid => 'csrf' );
		return;
	}

	my $now = DateTime->now( time_zone => 'Europe/Berlin' )->epoch;

	if ( $self->param('action') eq 'delete' ) {
		if (
			not $self->authenticate(
				$self->current_user->{name},
				$self->param('password')
			)
		  )
		{
			$self->render( 'account', invalid => 'password' );
			return;
		}
		$self->app->mark_for_deletion_query->execute( $now,
			$self->current_user->{id} );
	}
	else {
		$self->app->mark_for_deletion_query->execute( undef,
			$self->current_user->{id} );
	}
	$self->redirect_to('account');
}

sub do_logout {
	my ($self) = @_;
	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render( 'login', invalid => 'csrf' );
		return;
	}
	$self->logout;
	$self->redirect_to('/login');
}

1;