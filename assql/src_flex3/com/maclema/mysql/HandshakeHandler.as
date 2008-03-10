package com.maclema.mysql
{
	import flash.events.Event;
	import flash.utils.ByteArray;
	
	/**
	 * This class handles completing the handshake between this driver
	 * and the mysql server
	 **/
	public class HandshakeHandler extends DataHandler
	{
		private static const AUTH_411_OVERHEAD:int = 33;
		
		private var username:String;
		private var password:String;
		private var database:String;
		
		private var connectWithDb:Boolean = false;
		
		private var inPacketCount:int = 0;
		
		private var savePacketSequence:int;
		
		public function HandshakeHandler(con:Connection, username:String, password:String, database:String)
		{
			super(con);
			
			this.username = username;
			this.password = password;
			this.database = database;
		}
		
		override protected function newPacket():void
		{
			inPacketCount++;
			var packet:Packet;
			var field_count:int;
			
			if ( inPacketCount == 1 )
			{
				con.server = new ServerInformation( nextPacket() );
				doHandshake();
			}
			else if ( inPacketCount == 2 )
			{
				packet= nextPacket();
				
				field_count = packet.readByte() & 0xFF;
				
				if ( field_count == 0xFE && packet.length < 9 )
				{
					//By sending this very specific reply server asks us to send scrambled
                  	//password in old format. The reply contains scramble_323.
                  	inPacketCount--;
                  	sendScramble323();
				}
				else if ( field_count == 0x00 )
				{
					//ok packet
					if ( connectWithDb )
					{
						//send command
						con.changeDatabaseTo(database);
					}
					else
					{
						//woop! were authenticated
						unregister();
						con.dispatchEvent(new Event(Event.CONNECT));
					}
				}
				else if ( field_count == 0xFF )
				{
					unregister();
					new ErrorHandler( packet, con );
				}
			}
			else if ( connectWithDb && inPacketCount == 3 )
			{
				packet = nextPacket();
				field_count = packet.readByte() & 0xFF;
				
				if ( field_count == 0x00 )
				{
					//woop! were authenticated
					unregister();
					con.dispatchEvent(new Event(Event.CONNECT));
				}
				else if ( field_count == 0xFF || field_count == -1 )
				{
					unregister();
					new ErrorHandler( packet, con );
				}
			}
		}
		
		private function doHandshake():void
		{
			if ( con.server.meetsVersion( 4, 1, 22 ) )
			{
				con.clientParam = 0;
				
				if ( database != null && database.length > 0 )
				{
					con.clientParam |= Mysql.CLIENT_CONNECT_WITH_DB;
					connectWithDb = true;
				}
				
				if ( con.server.isCapableOf( Mysql.CLIENT_LONG_FLAG ) )
				{
					con.clientParam |= Mysql.CLIENT_LONG_FLAG;
					con.hasLongColumnInfo = true;
				}
				
				//return found rows
                con.clientParam |= Mysql.CLIENT_FOUND_ROWS;
    
                //use the new password encryption
                con.clientParam |= Mysql.CLIENT_LONG_PASSWORD;
                
                //use the 4.1.1 protocol
                con.clientParam |= Mysql.CLIENT_PROTOCOL_41;
                
                //use transactions
                con.clientParam |= Mysql.CLIENT_TRANSACTIONS;
                
                //return multiple result sets
                con.clientParam |= Mysql.CLIENT_MULTI_RESULTS;
                
                if ( con.server.isCapableOf(Mysql.CLIENT_SECURE_CONNECTION) )
                {
                	con.clientParam |= Mysql.CLIENT_SECURE_CONNECTION;
                	doSecureAuthentication411();
                }
                else
                {
                	doAuthentication();
                }
			}
			else
			{
				throw new Error("Unsupported Server Version");
			}
		}
		
		/* completes the authentication */
		private function doAuthentication():void
		{
			//the packet to send
			var packet:Packet = new Packet();
			
			//write the client parameters
			//packet.writeShort( con.clientParam );
			packet.writeByte( con.clientParam & 0xFF );
			packet.writeByte( con.clientParam >>> 8 );
			
			// write the maximum packet sixe
			packet.writeThreeByteInt( Packet.maxThreeBytes );
			
			//the username
			packet.writeString(username);
			
			if ( password != null )
			{
				var scrambledPassword:ByteArray = Util.newCrypt( password, con.server.seed );
				packet.writeBytes( scrambledPassword );
				packet.writeByte(0x00);
			}
			else
			{
				//empty password
				packet.writeByte(0x00);
			}
			
			//are we connecting using a database name?
			if ( connectWithDb && database != null )
			{
			    packet.writeString(database);
			}
			
			packet.send(con.getSocket(), 1);
		}
	
		private function sendScramble323():void
		{
			var packet:Packet = new Packet();
			
			var seed323:String = con.server.seed.substring(0, 8);
			var scrambled323:ByteArray = Util.newCrypt(password, seed323);
			packet.writeBytes( scrambled323 );
			packet.writeByte(0x00);
			packet.send(con.getSocket(), ++savePacketSequence);
		}
		
		/* completes the authentication */
		private function doSecureAuthentication411():void
		{
			//the packet to send
			var packet:Packet = new Packet();
			
			//write the client parameters
			packet.writeByte( con.clientParam & 0xFF );
			packet.writeByte( con.clientParam >>> 8 );
			packet.writeByte( con.clientParam >>> 16 );
			packet.writeByte( con.clientParam >>> 24 );
			
			// write the maximum packet sixe
			packet.writeInt( Packet.maxThreeBytes );
			
			//language
			packet.writeByte( 8 ); //charset
			
			//the 23-byte null filler
			packet.writeNullBytes(23);
			
			//the username
			packet.writeString(username);
			
			if ( password != null )
			{
				packet.writeByte(0x14);
				var scrambledPassword:ByteArray = Util.scramble411( password, con.server.seed );
				
				packet.writeBytes(scrambledPassword);
			}
			else
			{
				//empty password
				packet.writeByte(0x00);
			}
			
			//are we connecting using a database name?
			if ( connectWithDb && database != null )
			{
			    packet.writeString(database);
			}
			
			savePacketSequence = packet.send(con.getSocket(), 1);
		}
	}
}