import React from 'react';
import './App.css';

var RestApiPrefix = 'http://localhost:4567'
//var RestApiPrefix = ''

function PokerCards(props) {
  const suitMap = { S: '♠', H: '♥', D: '♦', C: '♣' };
  return (
    <span>
      {props.cards.map((c, i) =>
        <span key={i} className={`pokercard suit-${c[0]}`}>{`${suitMap[c[0]]}${c.substring(1)}`}</span>
      )}
    </span>
  );
}

function getCredsHeader(creds) {
  return {headers: {'X-Username': creds}};
}

class PokerTable extends React.Component {
  // props:
  // credentials={this.state.credentials} username={this.state.username} tablename={this.state.tablename}
  constructor(props) {
    super(props);

    this.state = {
      clientId: Math.random().toString(36).substr(2, 5)
    };
    this.state = Object.assign(this.state, this.getInitState());
    this.tableClosed = false;
    // this.pollEvents = this.pollEvents.bind(this)
    this.handleActionButton = this.handleActionButton.bind(this);
    this.handleStartGame = this.handleStartGame.bind(this);
    this.handleAmountChange = this.handleAmountChange.bind(this);
    this.handleRebuy = this.handleRebuy.bind(this);
    this.refreshTimerId = setInterval(() => {
      this.setState((state) => {
        // 0 means timeout not active
        let secs = 0;
        if (state.gamestate && !state.gamestate.finished && state.whosnext
            && this.props.username == state.whosnext.player && state.deadline) {
          secs = Math.round((state.deadline - new Date().getTime()) / 1000);
          // -1 indicates imminent timeout
          secs = (secs <= 0 ? -1 : secs);
        }
        if (state.remainingSecs != secs) {
          this.setState({remainingSecs: secs});
        }
      return null;
      });
    }, 200);
  }

  getInitState() {
    return {
      gamestate: null,
      playercards: {},
      whosnext: null,
      error: null,
      raiseAmount: 20,
      deadline: null,
      remainingSecs: null
    };
  }

  getHeaders() {
    return {headers: {'X-Username': this.props.credentials}};
  }

  pollEvents() {
    console.log("pollEvents()");

    // console.log("pollEvents called, numberOfFetches: " + this.state.numberOfFetches);
    fetch(`${RestApiPrefix}/api/poll-events?channel=table-${this.props.tablename},player-${this.props.username}:${this.props.tablename}&dontclose&id=${this.state.clientId}`,
      this.getHeaders()
    ).then(response => {
      // console.log("pollEvents succeeded, numberOfFetches: " + this.state.numberOfFetches);
      if (response.ok) {
        var buffer = "";
        var reader = response.body.getReader();

        var processEvent = resp => {
          console.log(`Event with type ${resp.evt.type} received`, resp);
          if (resp.evt.type == "GameStateEvent") {
            let deadline = new Date().getTime() + resp.evt.event.remaining_time * 1000;
            this.setState({ "gamestate": resp.evt.event, "deadline": deadline, "remainingSecs": null });
          } else if (resp.evt.type == "WhosNextEvent") {
            this.setState({ "whosnext": resp.evt.event });
          } else if (resp.evt.type == "PlayerCardsEvent") {
            this.setState((state) => {
              var newobj = Object.assign({}, state.playercards);
              newobj[resp.evt.event.player] = resp.evt.event;
              return {"playercards": newobj};
            });
          }
        }

        function findNextEvent({done, value}) {
          var chunk = new TextDecoder("utf-8").decode(value);
          console.log("findNextEvent() chunk: ", chunk);
          var sep = "\n{\"separator\":\"cb935688-891a-45d1-9692-0275ab14be96\"}\n";
          if (done) {
            console.log("pollEvents got end-of-stream");
            return;
          }
          // console.log("got chunk: ", chunk);
          buffer += chunk;
          var ind;
          while ((ind = buffer.indexOf(sep)) >= 0) {
            var json = buffer.substring(0, ind);
            // console.log("json found: ", json);
            buffer = buffer.substring(ind + sep.length);
            // console.log("new buffer:", buffer);

            processEvent(JSON.parse(json));
          }
          return reader.read().then(findNextEvent);
        }

        console.log("pollEvents succeeded, got response", response);
        return reader.read().then(findNextEvent);
        // return response.json();
      } else {
        throw new Error(`State error: ${response.status} ${response.statusText} - ${response.text()}`);
      }
    }).catch(error => {
      console.error(`Fetch error: ${error}`);
      this.setState((state) => ({ gamestate: null, error: error }));
    });
  }

  async componentDidMount() {
    console.log("PokerTable.componentDidMount()");
    this.setState(this.getInitState());
    // cancel any /poll-events request currently running
    await fetch(`${RestApiPrefix}/api/cancel-poll?id=${this.state.clientId}`, this.getHeaders() );
    this.pollEvents();
  }

  componentDidUpdate(prev) {
    console.log("PokerTable.componentDidUpdate()");
    if (prev.credentials != this.props.credentials || prev.tablename != this.props.tablename) {
      this.componentDidMount();
    }
  }

  async handleStartGame(event) {
    // clear other players' old hand data
    this.setState(this.getInitState());
    try {
      var response = await fetch(`${RestApiPrefix}/api/tables/${this.props.tablename}/start`, Object.assign({
          method: "POST",
        }, this.getHeaders())
      )
      if (!response.ok) {
        throw new Error(`Fetch error: ${response.status} ${response.statusText} - ${await response.text()}`);
      }
    } catch (error) {
      console.error(`Fetch error: ${error}`);
      this.setState((state) => ({ gamestate: null, error: error }));
      alert(error);
    };
  }

  async handleActionButton(event, action) {
    var payload = {
      what: action,
    };
    if (['raise', 'bet'].includes(action)) {
      payload["raise_amount"] = this.state.raiseAmount;
    }
    // TODO block UI until ready
    var response = await fetch(`${RestApiPrefix}/api/tables/${this.props.tablename}/action`, Object.assign({
        method: "POST",
        body: JSON.stringify(payload)
      }, this.getHeaders())
    );
    if (!response.ok) alert(await response.text());
  }

  handleAmountChange(event) {
    this.setState({raiseAmount: event.target.value});
  }

  handleRebuy(event) {
    fetch(`${RestApiPrefix}/api/tables/${this.props.tablename}/rebuy`, Object.assign({
        method: "POST"
      }, this.getHeaders())
    );
  }

  render() {
    console.log("state:", this.state);
    if (!this.props.credentials) {
      return (<div>Please log in</div>);
    }
    if (!this.state.gamestate || !this.state.playercards) {
      return (<div> <button onClick={this.handleStartGame}>New deal</button> </div>);
    }
    if (!this.state.gamestate.pigs.find(p => p.name == this.props.username)) {
      return (<div>Not joined to the table</div>);
    }
    const suitMap = { S: '♠', H: '♥', D: '♦', C: '♣' };
    return (
      <div>
        <h3>Table {this.props.tablename}</h3>
        {this.state.gamestate.pigs.map((pig, i) => {
          return (
            <div key={pig.name} className={pig.inactive ? "player-inactive" : ""}>
              <h4 className={pig.name == this.props.username ? "myself" : ""} key={pig.name}>
                Player {pig.name}{i == this.state.gamestate.button && " (button)"
                }{i == this.state.gamestate.waiting_for && !this.state.gamestate.finished && " (in turn)"
                }{pig.folded && " (folded)"
                }{pig.inactive ? " (not playing)" : pig.money == 0 ? " (all-in)" : ""
                }{this.state.gamestate.winners.includes(pig.name) && " (winner)"
                }
              </h4>
              {this.state.playercards[pig.name] &&
                <div>
                  Cards: <PokerCards cards={this.state.playercards[pig.name].cards}/> ({this.state.playercards[pig.name].rank})
                </div>
              }
              <div>Money: {pig.money}</div>
              <div>Bet in this round: {pig.money_in_round}</div>
              {!this.state.gamestate.finished && this.state.whosnext && this.props.username == pig.name && this.props.username == this.state.whosnext.player &&
                <div>
                  Actions:
                  {this.state.whosnext.actions.map((act) => {
                    var needsraise = ['raise', 'bet'].includes(act);
                      return <span key={act}>
                        { needsraise &&
                          <input type="text" pattern="[0-9]+" onInput={this.handleAmountChange} value={this.state.raiseAmount}/>
                        }
                        <button onClick={(e) => this.handleActionButton(e, act)} className="actionButton">{act
                          }{needsraise && ` $${this.state.raiseAmount}`
                          }{act=="call" && ` $${this.state.whosnext.call_amount}`}
                        </button>
                      </span>;
                  })}
                  {this.state.remainingSecs &&
                    <div>
                      {this.state.remainingSecs < 0 ? "(timed out)" : `(${this.state.remainingSecs} secs)`}
                    </div>
                  }
                </div>
              }
              {this.state.gamestate.finished && this.props.username == pig.name && pig.money == 0 &&
                <div>
                  <button onClick={this.handleRebuy} className="rebuyButton">Rebuy</button>
                </div>
              }
              <div>
              </div>

              {/* "name": "p1",
      "starting_money": 1000,
      "money": 980,
      "last_action": null,
      "money_in_round": 0,
      "folded": false               */}
            </div>
          )
        })}
        <h3>Board</h3>
        <div>
          Community cards: <PokerCards cards={this.state.gamestate.community_cards}/>
        </div>
        <div>
          Money in pot: {this.state.gamestate.money_in_pot}
        </div>
        {this.state.gamestate.finished &&
        <div>
          <button onClick={this.handleStartGame}>New deal</button>
        </div>
        }
        {/* <pre>
          {JSON.stringify(this.state.gamestate, null, 2)}
        </pre> */}
      </div>
    );
  }

}

class LoginForm extends React.Component {
  constructor(props) {
    super(props);
    this.state = {
      username: this.props.username, pass: this.props.password
    };
    this.handleUsernameChange = this.handleUsernameChange.bind(this);
    this.handlePasswordChange = this.handlePasswordChange.bind(this);
    this.handleSubmit = this.handleSubmit.bind(this);
    this.handleLogout = this.handleLogout.bind(this);
  }

  handleUsernameChange(event) {
    this.setState({username: event.target.value});
  }
  handlePasswordChange(event) {
    this.setState({pass: event.target.value});
  }

  handleSubmit(event) {
    event.preventDefault();
    console.log("Logging in user " + this.state.username);
    var credentials = `${this.state.username}:${this.state.pass}`
    // check if password is ok
    fetch(`${RestApiPrefix}/api/tables`,
      {headers: {'X-Username': credentials}}
    ).then(response => {
      if (response.ok) {
        this.props.onLogin(this.state.username, this.state.pass, credentials);
      } else {
        alert("Invalid password");
      }
    });
  }

  handleLogout(event) {
    event.preventDefault();
    console.log("Logging out user " + this.state.username);
    this.props.onLogin("", "", "");
  }

  render() {
    if (this.props.loggedIn) {
      return <button onClick={this.handleLogout}>Log out {this.props.username}</button>
    } else
      return (
        <form onSubmit={this.handleSubmit}>
          <label>
            Player:
            <input type="text" value={this.state.username} onChange={this.handleUsernameChange} />
          </label>
          <br/>
          <label>
            Password:
            <input type="password" value={this.state.pass} onChange={this.handlePasswordChange} />
          </label>
          <input type="submit" value="Login" />
        </form>
      );
  }
}

class App extends React.Component {
  constructor(props) {
    super(props);
    console.log("sessionStorage: ", sessionStorage);
    this.state = {
      username: sessionStorage.getItem('friendspoker.username') || '',
      password: sessionStorage.getItem('friendspoker.password') || '',
      tablename: sessionStorage.getItem('friendspoker.tablename') || '',
      credentials: sessionStorage.getItem('friendspoker.credentials') || '',
      loggedIn: sessionStorage.getItem('friendspoker.loggedIn') == "true"
    };
    // if (this.state.credentials && this.state.credentials.split(":")[1]) {
    //   this.state.password = this.state.credentials.split(":")[1];
    // }
    this.onLogin = this.onLogin.bind(this);
    this.handleTableNameChange = this.handleTableNameChange.bind(this);
    this.handleJoin = this.handleJoin.bind(this);

    // this.handleTableNameChange = this.handleTableNameChange.bind(this);
  }

  updateState(h) {
    for (let key of ['username', 'password', 'tablename', 'credentials', "loggedIn"]) {
      if (h[key]) {
        sessionStorage.setItem(`friendspoker.${key}`, h[key]);
      }
    }
    this.setState(h);
  }

  onLogin(name, pass, credentials) {
    console.log(`onLogin(${name}, ${pass}) called`);
    this.updateState({ username: name, password: pass, credentials: credentials, loggedIn: name.length > 0 });
  }

  handleTableNameChange(event) {
    this.updateState({tablename: event.target.value});
  }

  async handleJoin(event) {
    event.preventDefault();

    // create if does not exist (may return error if exist)
    await fetch(`${RestApiPrefix}/api/tables/${this.state.tablename}`, Object.assign({
        method: "POST",
      }, getCredsHeader(this.state.credentials))
    );

    fetch(`${RestApiPrefix}/api/tables/${this.state.tablename}/join`, Object.assign({
        method: "POST",
      }, getCredsHeader(this.state.credentials))
    ).then(response => {
      if (response.ok) {
      } else {
        alert("Could not join");
      }
    });
  }

  render() {
    return (
      <div>
        <LoginForm loggedIn={this.state.loggedIn} username={this.state.username} password={this.state.password} tablename={this.state.tablename} onLogin={this.onLogin}/>
        <form onSubmit={this.handleJoin}>
          <label>
            Table:
            <input type="text" value={this.state.tablename} onChange={this.handleTableNameChange} />
          </label>
          <input type="submit" value="Join" />
        </form>
        {this.state.loggedIn &&
          <div className="App">
            <PokerTable credentials={this.state.credentials} username={this.state.username} tablename={this.state.tablename}/>
          </div>
        }
      </div>
    );
  }
}

export default App;
